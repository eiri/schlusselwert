-module(schlusselwert_bench).

-export([run/0]).

-define(SAMPLES, 5).

run() ->
    lists:foreach(fun run_set/1, sets()),
    ok.

sets() ->
    [
        {Count, Length, Prefix, Offset}
     || Count <- [3, 10, 100, 1000],
        Length <- [12, 13],
        Prefix <- [distinct, shared],
        Offset <- [0, 4]
    ].

run_set({Count, Length, Prefix, Offset}) ->
    Protocols = protocols(Count, Length, Prefix, Offset),
    {CompileUs, {ok, Matcher, Routes}} = timer:tc(fun() ->
        schlusselwert_match:compile(Protocols, Offset + Length)
    end),
    CompleteMap = complete_map(Protocols, Routes),
    Signature = signature(Count, Length, Prefix),
    Hit = <<0:(Offset * 8), Signature/binary>>,
    Miss = <<0:(Offset * 8), 255:(Length * 8)>>,
    Base = name(Count, Length, Prefix, Offset),
    io:format("~s compile_us=~B~n", [Base, CompileUs]),
    run_input(Base ++ " hit complete", Matcher, CompleteMap, Offset, Length, Hit, Count),
    run_input(
        Base ++ " hit fragmented",
        Matcher,
        CompleteMap,
        Offset,
        Length,
        binary:part(Hit, 0, byte_size(Hit) - 1),
        Count
    ),
    run_input(Base ++ " miss complete", Matcher, CompleteMap, Offset, Length, Miss, Count),
    run_input(
        Base ++ " miss fragmented",
        Matcher,
        CompleteMap,
        Offset,
        Length,
        binary:part(Miss, 0, byte_size(Miss) - 1),
        Count
    ).

run_input(Name, Matcher, CompleteMap, Offset, Length, Buffer, Count) ->
    Iterations = max(100, 1000 div Count),
    Linear = measure(fun() -> schlusselwert_match:linear(Matcher, Buffer) end, Iterations),
    Map = measure(fun() -> map_match(CompleteMap, Offset, Length, Buffer) end, Iterations),
    Indexed = measure(fun() -> schlusselwert_match:match(Matcher, Buffer) end, Iterations),
    report(Name, linear, Linear),
    report(Name, complete_map, Map),
    report(Name, german_index, Indexed),
    outcome(Name, Linear, Indexed).

measure(Fun, Iterations) ->
    _ = loop(Fun, 20, 0),
    Samples = [sample(Fun, Iterations) || _ <- lists:seq(1, ?SAMPLES)],
    Times = lists:sort([Time || {Time, _Reductions, _Memory} <- Samples]),
    Reductions = lists:sort([Value || {_Time, Value, _Memory} <- Samples]),
    Memory = lists:sort([Value || {_Time, _Reductions, Value} <- Samples]),
    #{
        median => median(Times),
        min => hd(Times),
        max => lists:last(Times),
        reductions => median(Reductions),
        memory => median(Memory)
    }.

sample(Fun, Iterations) ->
    {reductions, BeforeReductions} = process_info(self(), reductions),
    {memory, BeforeMemory} = process_info(self(), memory),
    {Time, _Hash} = timer:tc(fun() -> loop(Fun, Iterations, 0) end),
    {reductions, AfterReductions} = process_info(self(), reductions),
    {memory, AfterMemory} = process_info(self(), memory),
    Nanoseconds = Time * 1000 div Iterations,
    Reductions = (AfterReductions - BeforeReductions) div Iterations,
    {Nanoseconds, Reductions, AfterMemory - BeforeMemory}.

loop(_Fun, 0, Hash) ->
    Hash;
loop(Fun, Count, Hash) ->
    loop(Fun, Count - 1, Hash bxor erlang:phash2(Fun())).

report(Name, Matcher, Result) ->
    io:format(
        "~s matcher=~p median_ns=~B spread_ns=~B..~B reductions=~B memory_delta=~B~n",
        [
            Name,
            Matcher,
            maps:get(median, Result),
            maps:get(min, Result),
            maps:get(max, Result),
            maps:get(reductions, Result),
            maps:get(memory, Result)
        ]
    ).

outcome(Name, Linear, Indexed) ->
    LinearTime = maps:get(median, Linear),
    IndexedTime = maps:get(median, Indexed),
    Result =
        case IndexedTime of
            Time when Time * 100 < LinearTime * 95 -> helps;
            Time when Time * 100 > LinearTime * 105 -> loses;
            _ -> neutral
        end,
    io:format("~s german_index=~p~n", [Name, Result]).

median(Values) ->
    lists:nth(length(Values) div 2 + 1, Values).

map_match(_Map, Offset, Length, Buffer) when byte_size(Buffer) < Offset + Length ->
    more;
map_match(Map, Offset, Length, Buffer) ->
    maps:get(binary:part(Buffer, Offset, Length), Map, unknown).

complete_map(Protocols, Routes) ->
    lists:foldl(
        fun({Protocol, Route}, Map) ->
            [#{bytes := Bytes}] = maps:get(signatures, Protocol),
            Map#{Bytes => {match, Route}}
        end,
        #{},
        lists:zip(Protocols, tuple_to_list(Routes))
    ).

protocols(Count, Length, Prefix, Offset) ->
    [
        #{
            name => list_to_atom("bench_" ++ integer_to_list(Index)),
            upstream => #{host => "localhost", port => 10000 + Index},
            signatures => [
                #{
                    at => Offset,
                    bytes => signature(Index, Length, Prefix),
                    priority => Index
                }
            ]
        }
     || Index <- lists:seq(1, Count)
    ].

signature(Index, Length, distinct) ->
    pad(<<Index:32, Index:32>>, Length);
signature(Index, Length, shared) ->
    pad(<<"same", Index:32>>, Length).

pad(Bin, Length) ->
    Padding = Length - byte_size(Bin),
    <<Bin/binary, 0:(Padding * 8)>>.

name(Count, Length, Prefix, Offset) ->
    lists:flatten(
        io_lib:format("count=~B length=~B prefix=~p offset=~B", [Count, Length, Prefix, Offset])
    ).
