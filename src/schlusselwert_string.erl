-module(schlusselwert_string).

-compile({no_auto_import, [size/1]}).

-export([new/1, size/1, prefix/1, match/2, binary/1]).
-export_type([gstr/0]).

-opaque gstr() :: {short, binary()} | {long, non_neg_integer(), binary(), binary()}.

-spec new(binary()) -> gstr().
new(Bin) when byte_size(Bin) =< 12 ->
    {short, Bin};
new(Bin) ->
    {long, byte_size(Bin), binary:part(Bin, 0, 4), Bin}.

-spec size(gstr()) -> non_neg_integer().
size({short, Bin}) ->
    byte_size(Bin);
size({long, Size, _Prefix, _Bin}) ->
    Size.

-spec prefix(gstr()) -> binary().
prefix({short, Bin}) when byte_size(Bin) =< 4 ->
    Bin;
prefix({short, Bin}) ->
    binary:part(Bin, 0, 4);
prefix({long, _Size, Prefix, _Bin}) ->
    Prefix.

-spec match(gstr(), binary()) -> true | false | more.
match(String, Input) ->
    Bin = binary(String),
    Size = size(String),
    InputSize = byte_size(Input),
    Compared = min(Size, InputSize),
    case binary:part(Bin, 0, Compared) =:= binary:part(Input, 0, Compared) of
        true when InputSize < Size -> more;
        true -> true;
        false -> false
    end.

-spec binary(gstr()) -> binary().
binary({short, Bin}) ->
    Bin;
binary({long, _Size, _Prefix, Bin}) ->
    Bin.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

boundaries_test_() ->
    Bins = [<<>>, <<1>>, <<1, 2, 3, 4>>, <<1, 2, 3, 4, 5>>, <<0:96>>, <<0:104>>],
    [
        ?_assertEqual(
            {byte_size(Bin), binary:part(Bin, 0, min(4, byte_size(Bin))), Bin},
            begin
                String = new(Bin),
                {size(String), prefix(String), binary(String)}
            end
        )
     || Bin <- Bins
    ].

match_test_() ->
    Embedded = new(<<1, 0, 2>>),
    [
        ?_assertEqual(true, match(new(<<>>), <<>>)),
        ?_assertEqual(more, match(Embedded, <<>>)),
        ?_assertEqual(more, match(Embedded, <<1, 0>>)),
        ?_assertEqual(true, match(Embedded, <<1, 0, 2>>)),
        ?_assertEqual(true, match(Embedded, <<1, 0, 2, 3>>)),
        ?_assertEqual(false, match(Embedded, <<1, 1>>))
    ].

-endif.
