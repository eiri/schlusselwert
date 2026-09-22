-module(schlusselwert_proxy_tests).

-include_lib("eunit/include/eunit.hrl").

proxy_test_() ->
    {timeout, 10, fun proxy_flow/0}.

proxy_flow() ->
    {Backend, BackendPort, Fixture} = echo_fixture(),
    GatewayPort = free_port(),
    Path = temp_path(),
    ok = write_config(Path, GatewayPort, one, BackendPort, <<"hello">>, 16),
    application:set_env(schlusselwert, config_path, Path),
    application:set_env(schlusselwert, acceptors, 2),
    application:set_env(schlusselwert, connect_timeout, 100),
    {ok, Registry} = schlusselwert_registry:start_link(),
    unlink(Registry),
    {ok, Proxy} = schlusselwert_proxy:start_link(),
    unlink(Proxy),
    try
        {ok, Client} = connect(GatewayPort),
        ok = gen_tcp:send(Client, <<"he">>),
        timer:sleep(10),
        ok = gen_tcp:send(Client, <<"llo">>),
        ?assertEqual({ok, <<"hello">>}, gen_tcp:recv(Client, 5, 1000)),
        ok = gen_tcp:send(Client, <<"-again">>),
        ?assertEqual({ok, <<"-again">>}, gen_tcp:recv(Client, 6, 1000)),
        Metrics = schlusselwert:metrics(),
        One = maps:get(one, maps:get(protocols, Metrics)),
        ?assertEqual(11, maps:get(client_bytes, One)),
        ?assertEqual(11, maps:get(upstream_bytes, One)),

        ok = write_config(Path, GatewayPort, two, free_port(), <<"abcdefgh">>, 8),
        ok = schlusselwert:reload(),
        ok = gen_tcp:send(Client, <<"-old">>),
        ?assertEqual({ok, <<"-old">>}, gen_tcp:recv(Client, 4, 1000)),
        ok = gen_tcp:shutdown(Client, write),
        ?assertEqual({error, closed}, gen_tcp:recv(Client, 0, 1000)),

        #{workers := Workers} = sys:get_state(Proxy),
        Acceptor = hd([Pid || {Pid, accepting} <- maps:to_list(Workers)]),
        exit(Acceptor, kill),
        timer:sleep(10),
        {ok, Unknown} = connect(GatewayPort),
        ok = gen_tcp:send(Unknown, <<"xxxxx">>),
        ?assertEqual({error, closed}, gen_tcp:recv(Unknown, 0, 1000)),

        {ok, Failed} = connect(GatewayPort),
        ok = gen_tcp:send(Failed, <<"abcdefgh">>),
        ?assertEqual({error, closed}, gen_tcp:recv(Failed, 0, 1000)),

        {ok, Overflow} = connect(GatewayPort),
        ok = gen_tcp:send(Overflow, <<"abcd">>),
        timer:sleep(10),
        ok = gen_tcp:send(Overflow, <<"efghi">>),
        ?assertEqual({error, closed}, gen_tcp:recv(Overflow, 0, 1000)),

        {ok, Timeout} = connect(GatewayPort),
        ?assertEqual({error, closed}, gen_tcp:recv(Timeout, 0, 1000)),
        NewMetrics = schlusselwert:metrics(),
        ?assertEqual(1, maps:get(unknown, NewMetrics)),
        ?assertEqual(1, maps:get(upstream_failure, NewMetrics)),
        ?assertEqual(1, maps:get(probe_overflow, NewMetrics)),
        ?assertEqual(1, maps:get(probe_timeout, NewMetrics)),
        gen_tcp:close(Client)
    after
        gen_server:stop(Proxy),
        gen_server:stop(Registry),
        gen_tcp:close(Backend),
        exit(Fixture, shutdown),
        file:delete(Path),
        application:unset_env(schlusselwert, config_path),
        application:unset_env(schlusselwert, acceptors),
        application:unset_env(schlusselwert, connect_timeout)
    end.

connect(Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {packet, raw}, {active, false}], 1000).

echo_fixture() ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listener),
    Pid = spawn(fun() -> echo_accept(Listener) end),
    {Listener, Port, Pid}.

echo_accept(Listener) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} -> echo(Socket);
        {error, closed} -> ok
    end.

echo(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            ok = gen_tcp:send(Socket, Data),
            echo(Socket);
        {error, closed} ->
            gen_tcp:close(Socket)
    end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    gen_tcp:close(Socket),
    Port.

temp_path() ->
    filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "schlusselwert-proxy-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".config"
    ).

write_config(Path, GatewayPort, Name, BackendPort, Signature, Max) ->
    Config = #{
        listen => #{ip => {127, 0, 0, 1}, port => GatewayPort},
        probe => #{bytes => Max, timeout => 50},
        protocols => [
            #{
                name => Name,
                upstream => #{host => "127.0.0.1", port => BackendPort},
                signatures => [#{at => 0, bytes => Signature}]
            }
        ]
    },
    file:write_file(Path, io_lib:format("~p.~n", [Config])).
