import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Random "mo:base/Random";
import Text "mo:base/Text";
import Result "mo:base/Result";
import Time "mo:base/Time";
import Int "mo:base/Int";
import Sha256 "mo:sha2/Sha256";
import Hex "mo:encoding/Hex";
import Binary "mo:encoding/Binary";
import Account "mo:account";
import Vector "mo:vector";
import AccountIdentifier "mo:account-identifier";
import IcpLedgerInterface "./ledger_interface";
import IcpGovernanceInterface "./governance_interface";

shared ({ caller = owner }) actor class NeuronPool() = thisCanister {

    /////////////////
    /// Constants ///
    /////////////////

    // ICP ledger canister
    let IcpLedger = actor "ryjl3-tyaaa-aaaaa-aaaba-cai" : IcpLedgerInterface.Self;

    // ICP governance canister
    let IcpGovernance = actor "rrkah-fqaaa-aaaaa-aaaaq-cai" : IcpGovernanceInterface.Self;

    // The standard ICP transaction fee
    let ICP_PROTOCOL_FEE : Nat64 = 10_000;

    // 1 ICP in e8s
    let ONE_ICP : Nat64 = 100_000_000;

    /////////////
    /// Types ///
    /////////////

    public type Result<X, Y> = Result.Result<X, Y>;

    public type Operation = {
        action : Action;
        timestamp : Nat64;
    };

    public type OperationIndex = Nat;

    public type OperationResponse = Result<OperationIndex, Text>;

    public type Action = {
        #StakeTransfer : Any;
        #StakeWithdrawal : Any;
        #StakeDisburse : Any;
        #RewardSpawn : Any;
        #CreateNeuron : CreateNeuron;
    };

    public type CreateNeuron = {
        id : Nat64;
    };

    public type CanisterAccountsResult = Result<{ account_identifier : Text; icrc1_identifier : Text; balance : Nat }, ()>;

    //////////////////////
    /// Canister State ///
    //////////////////////

    stable let _operationHistory = Vector.new<Operation>();

    ////////////////////////
    /// Public Functions ///
    ////////////////////////

    // public shared ({ caller }) func controller_stake_neuron(amount : Nat64) : async OperationResponse {
    //     assert (caller == owner);
    //     return await stakeNeuron(amount);
    // };

    public shared ({ caller }) func get_canister_accounts() : async CanisterAccountsResult {
        assert (Principal.isAnonymous(caller) == false);
        return await getCanisterAccounts();
    };

    /////////////////////////////////
    /// Canister Neuron Functions ///
    /////////////////////////////////

    // WON'T WORK UNTIL CANISTERS CAN STAKE NEURONS
    private func stakeNeuron(amount : Nat64) : async OperationResponse {
        // guard clauses
        if (Option.isSome(mainNeuronId())) return #err("Main neuron has already been staked");
        if (amount < ONE_ICP + ICP_PROTOCOL_FEE) return #err("A minimum of 1.0001 ICP is needed to stake");

        // generate a random nonce that fits into Nat64
        let ?nonce = Random.Finite(await Random.blob()).range(64) else return #err("Failed to generate nonce");

        // controller is the canister
        let neuronController : Principal = Principal.fromActor(thisCanister);

        // neurons subaccounts contain random nonces so one controller can have many neurons
        let newSubaccount : Blob = computeNeuronStakingSubaccountBytes(neuronController, Nat64.fromNat(nonce));

        // the neuron account ID is a sub account of the governance canister
        let newNeuronAccount : Blob = AccountIdentifier.accountIdentifier(Principal.fromActor(IcpGovernance), newSubaccount);

        switch (await IcpLedger.transfer({ memo = Nat64.fromNat(nonce); from_subaccount = null; to = newNeuronAccount; amount = { e8s = amount - ICP_PROTOCOL_FEE }; fee = { e8s = ICP_PROTOCOL_FEE }; created_at_time = null })) {
            case (#Ok _) {
                // ClaimOrRefresh: finds the neuron by subaccount and checks if the memo matches the nonce
                let { command } = await IcpGovernance.manage_neuron({
                    id = null;
                    neuron_id_or_subaccount = null;
                    command = ? #ClaimOrRefresh({
                        by = ? #MemoAndController({
                            controller = ?neuronController;
                            memo = Nat64.fromNat(nonce);
                        });
                    });
                });

                let ?commandList = command else return #err("Failed to claim new neuron");

                switch (commandList) {
                    case (#ClaimOrRefresh { refreshed_neuron_id }) {

                        let ?{ id } = refreshed_neuron_id else return #err("Failed to retrieve new neuron Id");

                        // store the staked neuron in the log
                        return #ok(logOperation(#CreateNeuron({ id = id })));
                    };
                    case _ {
                        return #err("Failed to stake. " # debug_show commandList);
                    };
                };
            };
            case (#Err error) {
                return #err("Failed to transfer ICP: " # debug_show error);
            };
        };
    };

    // motoko version of this: https://github.com/dfinity/ic/blob/0f7973af4283f3244a08b87ea909b6f605d65989/rs/nervous_system/common/src/ledger.rs#L210
    private func computeNeuronStakingSubaccountBytes(controller : Principal, nonce : Nat64) : Blob {
        let hash = Sha256.Digest(#sha256);
        hash.writeArray([0x0c]);
        hash.writeArray(Blob.toArray(Text.encodeUtf8("neuron-stake")));
        hash.writeArray(Blob.toArray(Principal.toBlob(controller)));
        hash.writeArray(Binary.BigEndian.fromNat64(nonce)); // needs to be big endian bytes
        return hash.sum();
    };

    //////////////////////////
    /// Canister Functions ///
    //////////////////////////

    private func getCanisterAccounts() : async CanisterAccountsResult {
        return #ok({
            account_identifier = Principal.fromActor(thisCanister) |> AccountIdentifier.accountIdentifier(_, AccountIdentifier.defaultSubaccount()) |> Blob.toArray(_) |> Hex.encode(_);
            icrc1_identifier = Account.toText({
                owner = Principal.fromActor(thisCanister);
                subaccount = null;
            });
            balance = await IcpLedger.icrc1_balance_of({
                owner = Principal.fromActor(thisCanister);
                subaccount = null;
            });
        });
    };

    ///////////////////////////////////
    /// Operation History Functions ///
    ///////////////////////////////////

    private func logOperation(action : Action) : OperationIndex {
        Vector.add(
            _operationHistory,
            {
                action = action;
                timestamp = Time.now() |> Int.abs(_) |> Nat64.fromNat(_);
            },
        );

        return Vector.size(_operationHistory);
    };

    private func mainNeuronId() : ?Nat64 {
        for (op in Vector.vals(_operationHistory)) {
            switch (op.action) {
                case (#CreateNeuron { id }) {
                    return ?id;
                };
                case _ {
                    return null;
                };
            };
        };

        return null;
    };

};
