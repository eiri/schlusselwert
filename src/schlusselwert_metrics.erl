-module(schlusselwert_metrics).

-export([new/1, add/3, add/4, snapshot/2]).

-define(GLOBAL_SIZE, 8).
-define(PROTOCOL_SIZE, 5).

-type global_counter() ::
    accepted
    | unknown
    | probe_timeout
    | probe_overflow
    | upstream_failure
    | active_relay
    | client_bytes
    | upstream_bytes.
-type protocol_counter() ::
    matched | upstream_failure | active_relay | client_bytes | upstream_bytes.

-spec new(non_neg_integer()) -> atomics:atomics_ref().
new(ProtocolCount) when is_integer(ProtocolCount), ProtocolCount >= 0 ->
    atomics:new(?GLOBAL_SIZE + ProtocolCount * ?PROTOCOL_SIZE, [{signed, false}]).

-spec add(atomics:atomics_ref(), global_counter(), integer()) -> ok.
add(Ref, Counter, Delta) ->
    _ = atomics:add(Ref, global_index(Counter), Delta),
    ok.

-spec add(atomics:atomics_ref(), non_neg_integer(), protocol_counter(), integer()) -> ok.
add(Ref, Slot, Counter, Delta) ->
    _ = atomics:add(Ref, protocol_index(Slot, Counter), Delta),
    ok.

-spec snapshot(atomics:atomics_ref(), tuple()) -> map().
snapshot(Ref, Protocols) ->
    Global = maps:from_list([
        {Counter, atomics:get(Ref, global_index(Counter))}
     || Counter <- global_counters()
    ]),
    PerProtocol = maps:from_list([
        {maps:get(name, Route), protocol_snapshot(Ref, maps:get(slot, Route))}
     || Route <- tuple_to_list(Protocols)
    ]),
    Global#{protocols => PerProtocol}.

global_counters() ->
    [
        accepted,
        unknown,
        probe_timeout,
        probe_overflow,
        upstream_failure,
        active_relay,
        client_bytes,
        upstream_bytes
    ].

protocol_counters() ->
    [matched, upstream_failure, active_relay, client_bytes, upstream_bytes].

protocol_snapshot(Ref, Slot) ->
    maps:from_list([
        {Counter, atomics:get(Ref, protocol_index(Slot, Counter))}
     || Counter <- protocol_counters()
    ]).

global_index(accepted) -> 1;
global_index(unknown) -> 2;
global_index(probe_timeout) -> 3;
global_index(probe_overflow) -> 4;
global_index(upstream_failure) -> 5;
global_index(active_relay) -> 6;
global_index(client_bytes) -> 7;
global_index(upstream_bytes) -> 8.

protocol_index(Slot, Counter) ->
    ?GLOBAL_SIZE + Slot * ?PROTOCOL_SIZE + protocol_offset(Counter).

protocol_offset(matched) -> 1;
protocol_offset(upstream_failure) -> 2;
protocol_offset(active_relay) -> 3;
protocol_offset(client_bytes) -> 4;
protocol_offset(upstream_bytes) -> 5.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

snapshot_test() ->
    Protocols = {
        #{name => one, slot => 0},
        #{name => two, slot => 1}
    },
    Ref = new(2),
    ok = add(Ref, accepted, 2),
    ok = add(Ref, 0, matched, 1),
    ok = add(Ref, 1, client_bytes, 12),
    Snapshot = snapshot(Ref, Protocols),
    ?assertEqual(2, maps:get(accepted, Snapshot)),
    ?assertEqual(1, maps:get(matched, maps:get(one, maps:get(protocols, Snapshot)))),
    ?assertEqual(12, maps:get(client_bytes, maps:get(two, maps:get(protocols, Snapshot)))),
    ?assertEqual(0, maps:get(upstream_bytes, maps:get(two, maps:get(protocols, Snapshot)))).

-endif.
