-module(schlusselwert_match).

-export([compile/2, match/2, linear/2]).

-type route() :: #{
    name := atom(), host := string() | binary(), port := pos_integer(), slot := non_neg_integer()
}.
-type result() :: {match, route()} | more | unknown.

-spec compile([map()], pos_integer()) -> {ok, map(), tuple()} | {error, term()}.
compile(_Protocols, MaxProbeBytes) when not is_integer(MaxProbeBytes); MaxProbeBytes =< 0 ->
    {error, {invalid_probe_bytes, MaxProbeBytes}};
compile([], _MaxProbeBytes) ->
    {error, no_protocols};
compile(Protocols, MaxProbeBytes) when is_list(Protocols) ->
    try
        Names = [protocol_name(Protocol) || Protocol <- Protocols],
        unique_names(Names),
        {Entries, Routes} = compile_protocols(Protocols, MaxProbeBytes, 0, [], []),
        check_ambiguity(Entries),
        {Buckets, Specs} = index(Entries),
        Matcher = #{entries => Entries, buckets => Buckets, specs => Specs},
        {ok, Matcher, list_to_tuple(lists:reverse(Routes))}
    catch
        throw:{invalid, Reason} -> {error, Reason}
    end;
compile(Protocols, _MaxProbeBytes) ->
    {error, {invalid_protocols, Protocols}}.

-spec match(map(), binary()) -> result().
match(#{buckets := Buckets, specs := Specs}, Buffer) when is_binary(Buffer) ->
    Entries = candidates(Specs, Buckets, Buffer, []),
    choose(Entries, Buffer).

-spec linear(map(), binary()) -> result().
linear(#{entries := Entries}, Buffer) when is_binary(Buffer) ->
    choose(Entries, Buffer).

protocol_name(#{name := Name}) when is_atom(Name) ->
    Name;
protocol_name(Protocol) when is_map(Protocol) ->
    invalid({invalid_name, maps:get(name, Protocol, undefined)});
protocol_name(Protocol) ->
    invalid({invalid_protocol, Protocol}).

unique_names(Names) ->
    case length(Names) =:= length(lists:usort(Names)) of
        true -> ok;
        false -> invalid(duplicate_protocol_name)
    end.

compile_protocols([], _Max, _Slot, Entries, Routes) ->
    {Entries, Routes};
compile_protocols([Protocol | Rest], Max, Slot, Entries, Routes) ->
    Name = protocol_name(Protocol),
    {Host, Port} = upstream(Protocol),
    Route = #{name => Name, host => Host, port => Port, slot => Slot},
    Signatures = maps:get(signatures, Protocol, undefined),
    ProtocolEntries = signatures(Signatures, Max, Route),
    compile_protocols(Rest, Max, Slot + 1, ProtocolEntries ++ Entries, [Route | Routes]).

upstream(#{upstream := #{host := Host, port := Port}}) ->
    valid_host(Host),
    valid_port(Port),
    {Host, Port};
upstream(Protocol) ->
    invalid({invalid_upstream, maps:get(upstream, Protocol, undefined)}).

valid_host(Host) when is_binary(Host), byte_size(Host) > 0 ->
    ok;
valid_host(Host) when is_list(Host), Host =/= [] ->
    case io_lib:char_list(Host) of
        true -> ok;
        false -> invalid({invalid_host, Host})
    end;
valid_host(Host) ->
    invalid({invalid_host, Host}).

valid_port(Port) when is_integer(Port), Port >= 1, Port =< 65535 ->
    ok;
valid_port(Port) ->
    invalid({invalid_port, Port}).

signatures(Signatures, Max, Route) when is_list(Signatures), Signatures =/= [] ->
    [signature(Signature, Max, Route) || Signature <- Signatures];
signatures(Signatures, _Max, _Route) ->
    invalid({invalid_signatures, Signatures}).

signature(Signature, Max, Route) when is_map(Signature) ->
    At = maps:get(at, Signature, undefined),
    Bytes = maps:get(bytes, Signature, undefined),
    Priority = maps:get(priority, Signature, 0),
    valid_signature(At, Bytes, Priority, Max),
    String = schlusselwert_string:new(Bytes),
    #{at => At, string => String, rank => {Priority, byte_size(Bytes)}, route => Route};
signature(Signature, _Max, _Route) ->
    invalid({invalid_signature, Signature}).

valid_signature(At, _Bytes, _Priority, _Max) when not is_integer(At); At < 0 ->
    invalid({invalid_offset, At});
valid_signature(_At, Bytes, _Priority, _Max) when not is_binary(Bytes); byte_size(Bytes) =:= 0 ->
    invalid({invalid_bytes, Bytes});
valid_signature(_At, _Bytes, Priority, _Max) when not is_integer(Priority) ->
    invalid({invalid_priority, Priority});
valid_signature(At, Bytes, _Priority, Max) when At + byte_size(Bytes) > Max ->
    invalid({signature_too_long, At + byte_size(Bytes), Max});
valid_signature(_At, _Bytes, _Priority, _Max) ->
    ok.

-spec invalid(term()) -> no_return().
invalid(Reason) ->
    throw({invalid, Reason}).

check_ambiguity([]) ->
    ok;
check_ambiguity([Entry | Rest]) ->
    lists:foreach(fun(Other) -> check_pair(Entry, Other) end, Rest),
    check_ambiguity(Rest).

check_pair(
    Entry = #{rank := Rank, route := #{name := Left}},
    Other = #{rank := Rank, route := #{name := Right}}
) when Left =/= Right ->
    case compatible(Entry, Other) of
        true -> invalid({ambiguous_signatures, Left, Right});
        false -> ok
    end;
check_pair(_Left, _Right) ->
    ok.

compatible(#{at := AtA, string := StringA}, #{at := AtB, string := StringB}) ->
    BinA = schlusselwert_string:binary(StringA),
    BinB = schlusselwert_string:binary(StringB),
    Start = max(AtA, AtB),
    End = min(AtA + byte_size(BinA), AtB + byte_size(BinB)),
    End =< Start orelse
        binary:part(BinA, Start - AtA, End - Start) =:=
            binary:part(BinB, Start - AtB, End - Start).

index(Entries) ->
    {Buckets, Specs} = lists:foldl(
        fun(Entry = #{at := At, string := String}, {EntryBuckets, EntrySpecs}) ->
            Prefix = schlusselwert_string:prefix(String),
            Key = {At, byte_size(Prefix), Prefix},
            {maps:update_with(Key, fun(List) -> [Entry | List] end, [Entry], EntryBuckets), [
                {At, byte_size(Prefix)} | EntrySpecs
            ]}
        end,
        {#{}, []},
        Entries
    ),
    {Buckets, lists:usort(Specs)}.

candidates([], _Buckets, _Buffer, Entries) ->
    Entries;
candidates([{At, PrefixSize} | Rest], Buckets, Buffer, Entries) when
    byte_size(Buffer) >= At + PrefixSize
->
    Prefix = binary:part(Buffer, At, PrefixSize),
    Found = maps:get({At, PrefixSize, Prefix}, Buckets, []),
    candidates(Rest, Buckets, Buffer, Found ++ Entries);
candidates([{At, PrefixSize} | Rest], Buckets, Buffer, Entries) ->
    Pending = pending(At, PrefixSize, Buckets),
    candidates(Rest, Buckets, Buffer, Pending ++ Entries).

pending(At, PrefixSize, Buckets) ->
    lists:append([
        Entries
     || {{EntryAt, EntryPrefixSize, _Prefix}, Entries} <- maps:to_list(Buckets),
        EntryAt =:= At,
        EntryPrefixSize =:= PrefixSize
    ]).

choose(Entries, Buffer) ->
    {Complete, Partial} = lists:foldl(
        fun(Entry, {Matches, More}) ->
            case entry_match(Entry, Buffer) of
                true -> {[Entry | Matches], More};
                more -> {Matches, [Entry | More]};
                false -> {Matches, More}
            end
        end,
        {[], []},
        Entries
    ),
    resolve(Complete, Partial).

entry_match(#{at := At}, Buffer) when byte_size(Buffer) =< At ->
    more;
entry_match(#{at := At, string := String}, Buffer) ->
    schlusselwert_string:match(String, binary:part(Buffer, At, byte_size(Buffer) - At)).

resolve([], []) ->
    unknown;
resolve([], _Partial) ->
    more;
resolve(Complete, Partial) ->
    BestRank = lists:max([Rank || #{rank := Rank} <- Complete]),
    Best = [Entry || Entry = #{rank := Rank} <- Complete, Rank =:= BestRank],
    Names = lists:usort([Name || #{route := #{name := Name}} <- Best]),
    case Names of
        [_] ->
            maybe_wait(hd(Best), Partial);
        _ ->
            logger:warning(
                #{event => ambiguous_runtime_match, protocols => Names},
                #{domain => [schlusselwert]}
            ),
            unknown
    end.

maybe_wait(#{rank := Rank, route := #{name := Name}} = Best, Partial) ->
    Stronger = [
        Entry
     || Entry = #{rank := PartialRank, route := #{name := PartialName}} <- Partial,
        PartialName =/= Name,
        PartialRank > Rank
    ],
    case Stronger of
        [] -> {match, maps:get(route, Best)};
        _ -> more
    end.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

p(Name, Host, Port, Signatures) ->
    #{name => Name, upstream => #{host => Host, port => Port}, signatures => Signatures}.

compile_test_() ->
    Valid = p(one, "host", 1, [#{at => 0, bytes => <<"a">>}]),
    Invalid = [
        {no_protocols, []},
        {{invalid_name, <<"one">>}, [Valid#{name => <<"one">>}]},
        {duplicate_protocol_name, [Valid, Valid]},
        {{invalid_host, <<>>}, [Valid#{upstream => #{host => <<>>, port => 1}}]},
        {{invalid_port, 0}, [Valid#{upstream => #{host => "host", port => 0}}]},
        {{invalid_signatures, []}, [Valid#{signatures => []}]},
        {{invalid_offset, -1}, [Valid#{signatures => [#{at => -1, bytes => <<"a">>}]}]},
        {{invalid_bytes, <<>>}, [Valid#{signatures => [#{at => 0, bytes => <<>>}]}]},
        {{invalid_priority, high}, [
            Valid#{signatures => [#{at => 0, bytes => <<"a">>, priority => high}]}
        ]},
        {{signature_too_long, 9, 8}, [
            Valid#{signatures => [#{at => 4, bytes => <<"abcde">>}]}
        ]}
    ],
    [?_assertEqual({error, Reason}, compile(Protocols, 8)) || {Reason, Protocols} <- Invalid].

matching_test() ->
    Protocols = [
        p(one, "one", 1, [
            #{at => 0, bytes => <<"a">>},
            #{at => 4, bytes => <<"tail">>, priority => -1}
        ]),
        p(two, <<"two">>, 2, [#{at => 0, bytes => <<"abcd">>, priority => 1}]),
        p(three, "three", 3, [#{at => 0, bytes => <<"abce">>, priority => 1}])
    ],
    {ok, Matcher, _} = compile(Protocols, 8),
    ?assertEqual(more, match(Matcher, <<"a">>)),
    ?assertMatch({match, #{name := two}}, match(Matcher, <<"abcd">>)),
    ?assertMatch({match, #{name := one}}, match(Matcher, <<"xxxxtail">>)),
    ?assertEqual(unknown, match(Matcher, <<"zzzzz">>)),
    Buffers = [<<>>, <<"a">>, <<"ab">>, <<"abcd">>, <<"abce">>, <<"xxxxtail">>, <<"zzzzz">>],
    [?assertEqual(linear(Matcher, Buffer), match(Matcher, Buffer)) || Buffer <- Buffers].

ranking_test() ->
    Protocols = [
        p(short, "host", 1, [#{at => 0, bytes => <<"a">>, priority => 0}]),
        p(long, "host", 2, [#{at => 0, bytes => <<"abc">>, priority => 0}]),
        p(priority, "host", 3, [#{at => 0, bytes => <<"ab">>, priority => 1}])
    ],
    {ok, Matcher, _} = compile(Protocols, 4),
    ?assertEqual(more, match(Matcher, <<"a">>)),
    ?assertMatch({match, #{name := priority}}, match(Matcher, <<"ab">>)).

ambiguity_test() ->
    Left = p(left, "host", 1, [#{at => 0, bytes => <<"ab">>}]),
    Right = p(right, "host", 2, [#{at => 1, bytes => <<"bc">>}]),
    ?assertMatch({error, {ambiguous_signatures, _, _}}, compile([Left, Right], 4)),
    Same = p(left, "host", 1, [#{at => 0, bytes => <<"ab">>}, #{at => 0, bytes => <<"ab">>}]),
    ?assertMatch({ok, _, _}, compile([Same], 4)).

-endif.
