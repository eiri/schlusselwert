-module(schlusselwert_match_prop).

-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

matcher_property_test() ->
    ?assert(
        proper:quickcheck(prop_matches_linear(), [
            {numtests, 500}, {start_size, 1}, {max_size, 20}
        ])
    ).

prop_matches_linear() ->
    ?FORALL(
        {Specs, Buffer},
        {non_empty(list(signature())), binary()},
        begin
            Protocols = protocols(lists:sublist(Specs, 6)),
            {ok, Matcher, _} = schlusselwert_match:compile(Protocols, 8),
            schlusselwert_match:match(Matcher, Buffer) =:=
                schlusselwert_match:linear(Matcher, Buffer)
        end
    ).

signature() ->
    ?LET(
        {At, Bytes},
        {range(0, 4), non_empty(list(range(0, 255)))},
        {At, list_to_binary(lists:sublist(Bytes, max(1, 8 - At)))}
    ).

protocols(Specs) ->
    Names = [one, two, three, four, five, six],
    [
        #{
            name => Name,
            upstream => #{host => "host", port => 1000 + Priority},
            signatures => [#{at => At, bytes => Bytes, priority => Priority}]
        }
     || {{At, Bytes}, Name, Priority} <- zip3(Specs, Names, lists:seq(1, length(Specs)))
    ].

zip3([A | As], [B | Bs], [C | Cs]) ->
    [{A, B, C} | zip3(As, Bs, Cs)];
zip3(_, _, _) ->
    [].
