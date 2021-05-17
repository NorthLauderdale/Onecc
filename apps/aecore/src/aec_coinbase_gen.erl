%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%     Calculate coinbase table to meet a given inflation curve.
%%% @end
%%%-------------------------------------------------------------------
-module(aec_coinbase_gen).

-export([ csv_file/2
        , csv_file/3
        , erlang_module/2
        , erlang_module/3
        ]).

-define(INITIAL_TOKENS, 276450333499323152460728285).
-define(BLOCKS_PER_YEAR, 175200).  %% 365 * 24 * 20
-define(SLOW_START_BLOCKS, 960). %% 2 * 24 * 20 (2 days)

-define(MULTIPLIER, 1000000000000000000).

erlang_module(To, FileName) ->
    erlang_module(To, FileName, ?INITIAL_TOKENS).

erlang_module(To, FileName, InitialTokens) ->
    {ok, FD} = file:open(FileName, [write]),
    io:format(FD,
              "%%%-------------------------------------------------------------------\n"
              "%%% @copyright (C) 2018, Aeternity Anstalt\n"
              "%%% @doc\n"
              "%%%     Module generated by ~p\n"
              "%%%     Initial supply of tokens: ~p\n"
              "%%% @end\n"
              "%%%-------------------------------------------------------------------\n\n"
              "-module(aec_coinbase).\n"
              "-export([coinbase_at_height/1]).\n"
              "\n"
              "-define(MULTIPLIER, ~p).\n\n"
              "-spec coinbase_at_height(non_neg_integer()) -> non_neg_integer().\n\n"
              "coinbase_at_height(X) when not is_integer(X) orelse X < 0 ->\n"
              "    error({bad_height, X});\n"
             , [?MODULE, InitialTokens, ?MULTIPLIER]),
    Fun = fun({Height, Coinbase,_Existing}, LastCoinbase) ->
                  [io:format(FD, "coinbase_at_height(H) when H < ~p -> ~p * ?MULTIPLIER;\n",
                             [Height, LastCoinbase])
                   || LastCoinbase =/= undefined,
                      LastCoinbase =/= 0 orelse Height < ?SLOW_START_BLOCKS
                  ],
                  Coinbase
          end,
    LastCB = coinbase(0, undefined, To, InitialTokens, undefined, Fun),
    io:format(FD, "coinbase_at_height(_H) -> 0.\n", []),
    file:close(FD),
    case LastCB =:= 0 of
        true -> ok;
        false -> error({last_coinbase_not_zero, LastCB})
    end.

csv_file(To, FileName) ->
    csv_file(To, FileName, ?INITIAL_TOKENS).

csv_file(To, FileName, InitialTokens) ->
    {ok, FD} = file:open(FileName, [write]),
    Fun = fun({Height, Coinbase0, Existing}, _Acc) ->
                  Coinbase = Coinbase0 * ?MULTIPLIER,
                  Inflation = Coinbase * ?BLOCKS_PER_YEAR/ Existing,
                  io:format(FD, "~p;~p;~p;~p\n",
                            [Height, Coinbase, Existing, Inflation])
          end,
    ok = coinbase(0, undefined, To, InitialTokens, [], Fun),
    file:close(FD).

coinbase(Height, Last, To, Existing, Acc, Fun) ->
    Coinbase = coinbase_at_height(Height, Existing),
    NewExisting = Existing + Coinbase * ?MULTIPLIER,
    case Height =:= To of
        true ->
            Fun({Height, Coinbase, NewExisting}, Acc);
        false ->
            case Last =:= Coinbase of
                true ->
                    coinbase(Height + 1, Last, To, NewExisting, Acc, Fun);
                false ->
                    NewAcc = Fun({Height, Coinbase, NewExisting}, Acc),
                    coinbase(Height + 1, Coinbase, To, NewExisting, NewAcc, Fun)
            end
    end.

coinbase_at_height(0,_Existing) ->
    %% No coinbase at genesis block
    0;
coinbase_at_height(Height, Existing) when Height < ?SLOW_START_BLOCKS ->
    max(1, round(Existing * inflation_at_height(Height) / (?BLOCKS_PER_YEAR * ?MULTIPLIER)));
coinbase_at_height(Height, Existing) ->
    max(0, round(Existing * inflation_at_height(Height) / (?BLOCKS_PER_YEAR * ?MULTIPLIER))).

inflation_at_height(Height) when Height < ?SLOW_START_BLOCKS ->
    Height * 0.3 / ?SLOW_START_BLOCKS;
inflation_at_height(Height) ->
    Adjusted = Height - ?SLOW_START_BLOCKS,
    0.30/(1 + math:pow(Adjusted/(?BLOCKS_PER_YEAR * 0.8), 1.3)) - 0.0003.
