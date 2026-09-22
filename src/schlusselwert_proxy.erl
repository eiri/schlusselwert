-module(schlusselwert_proxy).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    #{ip := Ip, port := Port, acceptors := Count} = Settings = schlusselwert_registry:listen(),
    Options = [
        binary, {packet, raw}, {active, false}, {reuseaddr, true}, {exit_on_close, false}, {ip, Ip}
    ],
    case gen_tcp:listen(Port, Options) of
        {ok, Listener} ->
            State = #{listener => Listener, settings => Settings, workers => #{}},
            {ok, start_acceptors(Count, State)};
        {error, Reason} ->
            {stop, {listen, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({accepted, Pid}, State = #{workers := Workers}) ->
    case maps:get(Pid, Workers, undefined) of
        accepting ->
            Connected = State#{workers => Workers#{Pid => connected}},
            {noreply, start_acceptor(Connected)};
        _ ->
            {noreply, State}
    end;
handle_info({'EXIT', Pid, _Reason}, State = #{workers := Workers}) ->
    case maps:take(Pid, Workers) of
        {accepting, Rest} ->
            {noreply, start_acceptor(State#{workers => Rest})};
        {connected, Rest} ->
            {noreply, State#{workers => Rest}};
        error ->
            {noreply, State}
    end.

terminate(_Reason, #{listener := Listener, workers := Workers}) ->
    gen_tcp:close(Listener),
    lists:foreach(fun(Pid) -> exit(Pid, shutdown) end, maps:keys(Workers)),
    ok.

start_acceptors(0, State) ->
    State;
start_acceptors(Count, State) ->
    start_acceptors(Count - 1, start_acceptor(State)).

start_acceptor(State = #{listener := Listener, settings := Settings, workers := Workers}) ->
    Owner = self(),
    Pid = spawn_link(fun() -> accept(Listener, Settings, Owner) end),
    State#{workers => Workers#{Pid => accepting}}.

accept(Listener, Settings, Owner) ->
    case gen_tcp:accept(Listener) of
        {ok, Client} ->
            Owner ! {accepted, self()},
            connection(Client, Settings);
        {error, closed} ->
            ok;
        {error, Reason} ->
            exit({accept, Reason})
    end.

connection(Client, #{connect_timeout := ConnectTimeout}) ->
    Snapshot = schlusselwert_registry:get(),
    Ref = maps:get(counters, Snapshot),
    schlusselwert_metrics:add(Ref, accepted, 1),
    Timeout = maps:get(probe_timeout, Snapshot),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    try
        probe(Client, Snapshot, ConnectTimeout, Deadline, <<>>)
    after
        gen_tcp:close(Client)
    end.

probe(Client, Snapshot, ConnectTimeout, Deadline, Buffer) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            close_probe(Snapshot, probe_timeout);
        false ->
            recv_probe(Client, Snapshot, ConnectTimeout, Deadline, Buffer, Remaining)
    end.

recv_probe(Client, Snapshot, ConnectTimeout, Deadline, Buffer, Remaining) ->
    case gen_tcp:recv(Client, 0, Remaining) of
        {ok, Data} ->
            Ref = maps:get(counters, Snapshot),
            schlusselwert_metrics:add(Ref, client_bytes, byte_size(Data)),
            Max = maps:get(max_probe_bytes, Snapshot),
            case byte_size(Buffer) + byte_size(Data) > Max of
                true ->
                    close_probe(Snapshot, probe_overflow);
                false ->
                    classify(
                        Client, Snapshot, ConnectTimeout, Deadline, <<Buffer/binary, Data/binary>>
                    )
            end;
        {error, timeout} ->
            close_probe(Snapshot, probe_timeout);
        {error, closed} ->
            close_probe(Snapshot, unknown);
        {error, _Reason} ->
            close_probe(Snapshot, unknown)
    end.

classify(Client, Snapshot, ConnectTimeout, Deadline, Buffer) ->
    Matcher = maps:get(matcher, Snapshot),
    case schlusselwert_match:match(Matcher, Buffer) of
        {match, Route} ->
            matched(Client, Snapshot, ConnectTimeout, Buffer, Route);
        more ->
            probe(Client, Snapshot, ConnectTimeout, Deadline, Buffer);
        unknown ->
            close_probe(Snapshot, unknown)
    end.

close_probe(Snapshot, Counter) ->
    schlusselwert_metrics:add(maps:get(counters, Snapshot), Counter, 1),
    ok.

matched(Client, Snapshot, ConnectTimeout, Buffer, Route) ->
    Ref = maps:get(counters, Snapshot),
    Slot = maps:get(slot, Route),
    schlusselwert_metrics:add(Ref, Slot, matched, 1),
    schlusselwert_metrics:add(Ref, Slot, client_bytes, byte_size(Buffer)),
    Options = [binary, {packet, raw}, {active, false}, {exit_on_close, false}],
    Host = maps:get(host, Route),
    Port = maps:get(port, Route),
    case gen_tcp:connect(Host, Port, Options, ConnectTimeout) of
        {ok, Upstream} ->
            replay(Client, Upstream, Snapshot, Route, Buffer);
        {error, Reason} ->
            upstream_failure(Snapshot, Route, Reason)
    end.

replay(Client, Upstream, Snapshot, Route, Buffer) ->
    case gen_tcp:send(Upstream, Buffer) of
        ok ->
            start_relay(Client, Upstream, Snapshot, Route);
        {error, Reason} ->
            gen_tcp:close(Upstream),
            upstream_failure(Snapshot, Route, Reason)
    end.

upstream_failure(Snapshot, Route, Reason) ->
    Ref = maps:get(counters, Snapshot),
    Slot = maps:get(slot, Route),
    schlusselwert_metrics:add(Ref, upstream_failure, 1),
    schlusselwert_metrics:add(Ref, Slot, upstream_failure, 1),
    logger:warning(
        #{event => upstream_failure, protocol => maps:get(name, Route), reason => Reason},
        #{domain => [schlusselwert]}
    ).

start_relay(Client, Upstream, Snapshot, Route) ->
    case {inet:setopts(Client, [{active, once}]), inet:setopts(Upstream, [{active, once}])} of
        {ok, ok} ->
            Ref = maps:get(counters, Snapshot),
            Slot = maps:get(slot, Route),
            schlusselwert_metrics:add(Ref, active_relay, 1),
            schlusselwert_metrics:add(Ref, Slot, active_relay, 1),
            try
                relay(Client, Upstream, Snapshot, Route, true, true)
            after
                schlusselwert_metrics:add(Ref, active_relay, -1),
                schlusselwert_metrics:add(Ref, Slot, active_relay, -1),
                gen_tcp:close(Upstream)
            end;
        {_ClientResult, _UpstreamResult} ->
            gen_tcp:close(Upstream)
    end.

relay(_Client, _Upstream, _Snapshot, _Route, false, false) ->
    ok;
relay(Client, Upstream, Snapshot, Route, ClientOpen, UpstreamOpen) ->
    receive
        {tcp, Client, Data} ->
            relay_data(client, Client, Upstream, Snapshot, Route, Data, UpstreamOpen);
        {tcp, Upstream, Data} ->
            relay_data(upstream, Upstream, Client, Snapshot, Route, Data, ClientOpen);
        {tcp_closed, Client} ->
            _ = gen_tcp:shutdown(Upstream, write),
            relay(Client, Upstream, Snapshot, Route, false, UpstreamOpen);
        {tcp_closed, Upstream} ->
            _ = gen_tcp:shutdown(Client, write),
            relay(Client, Upstream, Snapshot, Route, ClientOpen, false);
        {tcp_error, Client, _Reason} ->
            ok;
        {tcp_error, Upstream, _Reason} ->
            ok;
        shutdown ->
            ok;
        _Other ->
            relay(Client, Upstream, Snapshot, Route, ClientOpen, UpstreamOpen)
    end.

relay_data(Direction, Source, Target, Snapshot, Route, Data, TargetOpen) ->
    case gen_tcp:send(Target, Data) of
        ok ->
            count_bytes(Direction, Snapshot, Route, byte_size(Data)),
            case inet:setopts(Source, [{active, once}]) of
                ok ->
                    relay_sides(Direction, Source, Target, Snapshot, Route, TargetOpen);
                {error, _Reason} ->
                    ok
            end;
        {error, _Reason} ->
            ok
    end.

relay_sides(client, Client, Upstream, Snapshot, Route, UpstreamOpen) ->
    relay(Client, Upstream, Snapshot, Route, true, UpstreamOpen);
relay_sides(upstream, Upstream, Client, Snapshot, Route, ClientOpen) ->
    relay(Client, Upstream, Snapshot, Route, ClientOpen, true).

count_bytes(client, Snapshot, Route, Size) ->
    Ref = maps:get(counters, Snapshot),
    schlusselwert_metrics:add(Ref, client_bytes, Size),
    schlusselwert_metrics:add(Ref, maps:get(slot, Route), client_bytes, Size);
count_bytes(upstream, Snapshot, Route, Size) ->
    Ref = maps:get(counters, Snapshot),
    schlusselwert_metrics:add(Ref, upstream_bytes, Size),
    schlusselwert_metrics:add(Ref, maps:get(slot, Route), upstream_bytes, Size).
