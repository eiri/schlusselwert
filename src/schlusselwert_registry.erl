-module(schlusselwert_registry).

-compile({no_auto_import, [get/0]}).

-behaviour(gen_server).

-export([start_link/0, reload/0, get/0, summary/0, listen/0, metrics/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(KEY, {schlusselwert, registry}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec reload() -> ok | {error, term()}.
reload() ->
    gen_server:call(?MODULE, reload).

-spec get() -> map().
get() ->
    persistent_term:get(?KEY).

-spec summary() -> map().
summary() ->
    Snapshot = get(),
    Protocols = tuple_to_list(maps:get(protocols, Snapshot)),
    #{
        version => maps:get(version, Snapshot),
        names => [maps:get(name, Route) || Route <- Protocols],
        targets => [maps:with([name, host, port], Route) || Route <- Protocols],
        max_probe_bytes => maps:get(max_probe_bytes, Snapshot),
        probe_timeout => maps:get(probe_timeout, Snapshot)
    }.

-spec listen() -> map().
listen() ->
    gen_server:call(?MODULE, listen).

-spec metrics() -> map().
metrics() ->
    #{version := Version, counters := Ref, protocols := Protocols} = get(),
    (schlusselwert_metrics:snapshot(Ref, Protocols))#{version => Version}.

init([]) ->
    Path = application:get_env(schlusselwert, config_path, "priv/signatures.config"),
    case build(Path, 1) of
        {ok, Snapshot, Listener} ->
            case runtime_settings(Listener) of
                {ok, Settings} ->
                    persistent_term:put(?KEY, Snapshot),
                    {ok, #{path => Path, version => 1, listen => Settings}};
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(reload, _From, State = #{path := Path, version := Version}) ->
    case build(Path, Version + 1) of
        {ok, Snapshot, _Listener} ->
            persistent_term:put(?KEY, Snapshot),
            {reply, ok, State#{version => Version + 1}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(listen, _From, State) ->
    {reply, maps:get(listen, State), State}.

handle_cast(_Request, State) ->
    {noreply, State}.

build(Path, Version) ->
    case file:consult(Path) of
        {ok, [Config]} when is_map(Config) -> compile_config(Config, Version);
        {ok, Terms} -> {error, {invalid_config_terms, length(Terms)}};
        {error, Reason} -> {error, {consult, Reason}}
    end.

compile_config(Config, Version) ->
    case config_parts(Config) of
        {ok, Listener, MaxProbeBytes, ProbeTimeout, Protocols} ->
            case schlusselwert_match:compile(Protocols, MaxProbeBytes) of
                {ok, Matcher, ProtocolTuple} ->
                    Counters = schlusselwert_metrics:new(tuple_size(ProtocolTuple)),
                    {ok,
                        #{
                            version => Version,
                            matcher => Matcher,
                            protocols => ProtocolTuple,
                            max_probe_bytes => MaxProbeBytes,
                            probe_timeout => ProbeTimeout,
                            counters => Counters
                        },
                        Listener};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

config_parts(#{
    listen := Listener,
    probe := #{bytes := MaxProbeBytes, timeout := ProbeTimeout},
    protocols := Protocols
}) ->
    case valid_listener(Listener) of
        ok when is_integer(ProbeTimeout), ProbeTimeout > 0 ->
            {ok, Listener, MaxProbeBytes, ProbeTimeout, Protocols};
        ok ->
            {error, {invalid_probe_timeout, ProbeTimeout}};
        Error ->
            Error
    end;
config_parts(_Config) ->
    {error, invalid_config}.

valid_listener(#{ip := Ip, port := Port}) when is_integer(Port), Port >= 1, Port =< 65535 ->
    case inet:ntoa(Ip) of
        {error, einval} -> {error, {invalid_listen_ip, Ip}};
        _ -> ok
    end;
valid_listener(#{port := Port}) ->
    {error, {invalid_listen_port, Port}};
valid_listener(Listener) ->
    {error, {invalid_listener, Listener}}.

runtime_settings(Listener) ->
    Acceptors = application:get_env(schlusselwert, acceptors, 4),
    ConnectTimeout = application:get_env(schlusselwert, connect_timeout, 1000),
    case {Acceptors, ConnectTimeout} of
        {A, T} when is_integer(A), A > 0, is_integer(T), T > 0 ->
            {ok, Listener#{acceptors => A, connect_timeout => T}};
        _ ->
            {error, {invalid_runtime_settings, Acceptors, ConnectTimeout}}
    end.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

reload_test() ->
    Path = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "schlusselwert-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".config"
    ),
    ok = write_config(Path, one),
    OldPath = application:get_env(schlusselwert, config_path),
    application:set_env(schlusselwert, config_path, Path),
    {ok, Pid} = start_link(),
    unlink(Pid),
    First = get(),
    FirstRef = maps:get(counters, First),
    ok = schlusselwert_metrics:add(FirstRef, accepted, 3),
    ok = write_config(Path, two),
    ok = reload(),
    Second = get(),
    ?assertEqual(2, maps:get(version, Second)),
    ?assertEqual(0, maps:get(accepted, metrics())),
    ?assertEqual(
        3, maps:get(accepted, schlusselwert_metrics:snapshot(FirstRef, maps:get(protocols, First)))
    ),
    Summary = summary(),
    ?assertEqual([two], maps:get(names, Summary)),
    ?assertNot(maps:is_key(matcher, Summary)),
    ok = file:write_file(Path, <<"bad.">>),
    ?assertMatch({error, _}, reload()),
    ?assert(get() =:= Second),
    ok = gen_server:stop(Pid),
    restore_path(OldPath),
    ok = file:delete(Path).

write_config(Path, Name) ->
    Config = #{
        listen => #{ip => {127, 0, 0, 1}, port => 8080},
        probe => #{bytes => 8, timeout => 100},
        protocols => [
            #{
                name => Name,
                upstream => #{host => "localhost", port => 9000},
                signatures => [#{at => 0, bytes => <<"x">>}]
            }
        ]
    },
    file:write_file(Path, io_lib:format("~p.~n", [Config])).

restore_path({ok, Path}) ->
    application:set_env(schlusselwert, config_path, Path);
restore_path(undefined) ->
    application:unset_env(schlusselwert, config_path).

-endif.
