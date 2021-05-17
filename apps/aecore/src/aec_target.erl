-module(aec_target).

%% API
-export([recalculate/1,
         verify/2]).

-include_lib("aeminer/include/aeminer.hrl").

%% Target recalculation.
%%
%% Some concepts:
%%
%%    Difficulty = HIGHEST_TARGET / Target
%%    Rate       = Capacity / Difficulty  (blocks/ms)
%%    Capacity   = number of potential solutions per ms generated by miners
%%
%%    DesiredTimeBetweenBlocks = aec_governance:expected_block_mine_rate()
%%    DesiredRate              = 1 / DesiredTimeBetweenBlocks
%%
%% The basic idea of the algorithm is to estimate the current network capacity
%% based on the `N` (= 17) previous blocks and use that to set the new
%% target:
%%
%%    NewDifficulty = EstimatedCapacity / DesiredRate
%%    NewTarget     = HIGHEST_TARGET / NewDifficulty
%%                  = HIGHEST_TARGET * DesiredRate / EstimatedCapacity
%%
%% We can estimate the network capacity used to mine a given block `i` as
%%
%%    EstimatedCapacity[i] = Difficulty[i] / MiningTime[i]
%%    MiningTime[i]        = Time[i] - Time[i - 1]
%%
%% The estimated capacity across all `N` blocks is then the weighted (by time)
%% average of the estimated capacities for each block.
%%
%%    EstimatedCapacity = Sum(EstimatedCapacity[i] * MiningTime[i]) / TotalTime
%%                      = Sum(Difficulty[i]) / TotalTime
%%                      = Sum(HIGHEST_TARGET / Target[i]) / TotalTime
%%
%% To get a good trade-off between response time and stability we use the
%% DigiShield v3 algorithm (https://github.com/zawy12/difficulty-algorithms/issues/9)
%% and therefore we compute a tempered TotalTime (total solve time in ^^):
%%
%%    TotalTime'        = Sum(SolveTime[i])
%%    SolveTime[i]      = max(-FTL, min(6 * DesiredTimeBetweenBlocks, Time[i] - Time[i-1]))
%%    TemperedTotalTime = 0.75 * N * DesiredTimeBetweenBlocks + 0.2523 * TotalTime    %% DigiShield v3
%%
%% Where FTL = Future Time Limit - i.e. the time a block is allowed to be
%% "from the future". We use 9 minutes (540 s).
%%
%% Now, the problem is that we can't do any floating point arithmetic (to
%% ensure the calculation can be verified by other nodes), so we pick a
%% reasonably big integer K (= HIGHEST_TARGET * 2^32) and compute
%%
%%    EstimatedCapacity ≈ Sum(K * HIGHEST_TARGET div Target[i]) / TotalTime / K
%%    TemperedTotalTime ≈ (3 * N * DesiredTimeBetweenBlocks) div 4 +
%%                           (2523 * TotalTime') div 10000
%%
%% Then
%%
%%    NewTarget = HIGHEST_TARGET * DesiredRate / EstimatedCapacity
%%              ≈ HIGHEST_TARGET * DesiredRate * TemperedTotalTime * K / Sum(K * HIGHEST_TARGET div Target[i])
%%              ≈ DesiredRate * TemperedTotalTime * K / Sum(K div Target[i])
%%              ≈ TemperedTotalTime * K div (DesiredTimeBetweenBlocks * Sum(K div Target[i]))
%%
-spec recalculate(nonempty_list(aec_headers:header())) -> non_neg_integer().
recalculate(PrevHeaders0) ->
    N                        = aec_governance:key_blocks_to_check_difficulty_count(),
    N                        = length(PrevHeaders0) - 1, %% Sanity check.
    %% Ensure the list of previous headers are in order - oldest first.
    SortFun                  = fun(H1, H2) -> aec_headers:height(H1) =< aec_headers:height(H2) end,
    PrevHeaders              = lists:sort(SortFun, PrevHeaders0),
    K                        = aeminer_pow:scientific_to_integer(?HIGHEST_TARGET_SCI) * (1 bsl 32),
    SumKDivTargets           = lists:sum([ K div aeminer_pow:scientific_to_integer(aec_headers:target(Hd))
                                           || Hd <- tl(PrevHeaders) ]),
    DesiredTimeBetweenBlocks = aec_governance:expected_block_mine_rate(),
    TotalSolveTime           = total_solve_time(PrevHeaders),
    TemperedTST              = (3 * N * DesiredTimeBetweenBlocks) div 4 + (2523 * TotalSolveTime) div 10000,
    NewTargetInt             = TemperedTST * K div (DesiredTimeBetweenBlocks * SumKDivTargets),
    min(?HIGHEST_TARGET_SCI, aeminer_pow:integer_to_scientific(NewTargetInt)).

recalculate_from_stripped(TimesAndTargets) ->
    N                        = aec_governance:key_blocks_to_check_difficulty_count(),
    N                        = length(TimesAndTargets) - 1, %% Sanity check.
    K                        = aeminer_pow:scientific_to_integer(?HIGHEST_TARGET_SCI) * (1 bsl 32),
    SumKDivTargets           = lists:sum([ K div aeminer_pow:scientific_to_integer(Target)
                                           || {Target, _} <- tl(TimesAndTargets) ]),
    DesiredTimeBetweenBlocks = aec_governance:expected_block_mine_rate(),
    TotalSolveTime           = total_solve_time_from_stripped(TimesAndTargets),
    TemperedTST              = (3 * N * DesiredTimeBetweenBlocks) div 4 + (2523 * TotalSolveTime) div 10000,
    NewTargetInt             = TemperedTST * K div (DesiredTimeBetweenBlocks * SumKDivTargets),
    min(?HIGHEST_TARGET_SCI, aeminer_pow:integer_to_scientific(NewTargetInt)).

-spec verify(aec_headers:header(), nonempty_list(term())) ->
          ok | {error, {wrong_target, non_neg_integer(), non_neg_integer()}}.
verify(Top, TimesAndTargets) ->
    HeaderTarget = aec_headers:target(Top),
    ExpectedTarget = recalculate_from_stripped(TimesAndTargets),
    case HeaderTarget == ExpectedTarget of
        true ->
            ok;
        false ->
            {error, {wrong_target, HeaderTarget, ExpectedTarget}}
    end.

%% Internals

-spec total_solve_time([aec_headers:header()]) -> integer().
total_solve_time(Headers) ->
    Min = -aec_governance:accepted_future_block_time_shift(),
    Max = 6 * aec_governance:expected_block_mine_rate(),
    total_solve_time(Headers, {Min, Max}, 0).

total_solve_time([_], _MinMax, Acc) -> Acc;
total_solve_time([Hdr2 | [Hdr1 | _] = Hdrs], MinMax = {Min, Max}, Acc) ->
    SolveTime0 = aec_headers:time_in_msecs(Hdr1) - aec_headers:time_in_msecs(Hdr2),
    SolveTime =
        if SolveTime0 < Min -> Min;
           SolveTime0 > Max -> Max;
           true             -> SolveTime0
        end,
    total_solve_time(Hdrs, MinMax, Acc + SolveTime).

-spec total_solve_time_from_stripped([aec_headers:header()]) -> integer().
total_solve_time_from_stripped(TimesAndTargets) ->
    Min = -aec_governance:accepted_future_block_time_shift(),
    Max = 6 * aec_governance:expected_block_mine_rate(),
    total_solve_time_from_stripped(TimesAndTargets, {Min, Max}, 0).

total_solve_time_from_stripped([_], _MinMax, Acc) -> Acc;
total_solve_time_from_stripped([{_, T2} | [{_, T1} | _] = TimesAndTargets], MinMax = {Min, Max}, Acc) ->
    SolveTime0 = T1 - T2,
    SolveTime =
        if SolveTime0 < Min -> Min;
           SolveTime0 > Max -> Max;
           true             -> SolveTime0
        end,
    total_solve_time_from_stripped(TimesAndTargets, MinMax, Acc + SolveTime).
