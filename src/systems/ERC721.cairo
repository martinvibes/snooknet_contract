#[starknet::contract]
mod NFTContract {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use zeroable::Zeroable;
    use traits::Into;
    use traits::TryInto;
    use option::OptionTrait;
    use array::ArrayTrait;

    const LOW_LEVEL_THRESHOLD: u8 = 5; // Low-level NFTs have level <= 5
    const ACCURACY_BOOST: u128 = 110; // +10% accuracy (110% of base)
    const BOOST_MATCHES: u32 = 3; // Boost lasts for 3 matches
    const EPHEMERAL_DURATION: u64 = 48 * 3600; // 48 hours in seconds

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        owners: LegacyMap<u256, ContractAddress>,
        token_levels: LegacyMap<u256, u8>, // NFT level (for burn boost)
        token_uris: LegacyMap<u256, felt252>,
        token_expirations: LegacyMap<u256, u64>, // Expiration timestamp for ephemeral NFTs
        balances: LegacyMap<ContractAddress, u256>,
        token_count: u256,
        boost_status: LegacyMap<ContractAddress, BoostStatus>, // Tracks boost for each user
        leases: LegacyMap<u256, Lease>, // Tracks lease details
        admin: ContractAddress,
    }

    #[derive(Copy, Drop, Serde)]
    struct BoostStatus {
        matches_remaining: u32, // Matches left for boost
        accuracy_multiplier: u128, // 110 for +10% boost
    }

    #[derive(Copy, Drop, Serde)]
    struct Lease {
        lessee: ContractAddress,
        expiry: u64, // Timestamp when lease expires
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
        BoostApplied: BoostApplied,
        LeaseStarted: LeaseStarted,
        LeaseEnded: LeaseEnded,
        NFTBurned: NFTBurned,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct BoostApplied {
        user: ContractAddress,
        matches: u32,
        accuracy_multiplier: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct LeaseStarted {
        token_id: u256,
        lessee: ContractAddress,
        expiry: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct LeaseEnded {
        token_id: u256,
        lessee: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct NFTBurned {
        token_id: u256,
        owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, name: felt252, symbol: felt252) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.admin.write(get_caller_address());
    }

    #[external(v0)]
    impl NFTContractImpl of INFTContract {
        fn create_nft(ref self: ContractState, name: felt252, symbol: felt252) {
            assert(get_caller_address() == self.admin.read(), 'Only admin');
            self.name.write(name);
            self.symbol.write(symbol);
        }

        fn mint_nft(
            ref self: ContractState,
            recipient: ContractAddress,
            level: u8,
            token_uri: felt252,
            is_ephemeral: bool,
        ) -> u256 {
            assert(recipient.is_non_zero(), 'Invalid recipient');
            let token_id = self.token_count.read();
            self.owners.write(token_id, recipient);
            self.token_levels.write(token_id, level);
            self.token_uris.write(token_id, token_uri);
            if is_ephemeral {
                let expiry = get_block_timestamp() + EPHEMERAL_DURATION;
                self.token_expirations.write(token_id, expiry);
            }
            self.balances.write(recipient, self.balances.read(recipient) + 1.into());
            self.token_count.write(token_id + 1.into());

            self.emit(Event::Transfer(Transfer {
                from: Zeroable::zero(),
                to: recipient,
                token_id,
            }));

            token_id
        }

        fn lease_nft(ref self: ContractState, token_id: u256, lessee: ContractAddress, duration: u64) {
            let owner = self.owners.read(token_id);
            assert(owner.is_non_zero(), 'NFT does not exist');
            assert(get_caller_address() == owner, 'Only owner');
            assert(lessee.is_non_zero(), 'Invalid lessee');
            assert(self.token_expirations.read(token_id) == 0 || get_block_timestamp() < self.token_expirations.read(token_id), 'NFT expired');
            
            let expiry = get_block_timestamp() + duration;
            self.leases.write(token_id, Lease { lessee, expiry });

            self.emit(Event::LeaseStarted(LeaseStarted {
                token_id,
                lessee,
                expiry,
            }));
        }

        fn burn_nft(ref self: ContractState, token_id: u256) {
            let owner = self.owners.read(token_id);
            assert(owner.is_non_zero(), 'NFT does not exist');
            assert(get_caller_address() == owner, 'Only owner');
            assert(self.token_expirations.read(token_id) == 0 || get_block_timestamp() < self.token_expirations.read(token_id), 'NFT expired');

            // Check if NFT is low-level for boost
            let level = self.token_levels.read(token_id);
            if level <= LOW_LEVEL_THRESHOLD {
                self.boost_status.write(owner, BoostStatus {
                    matches_remaining: BOOST_MATCHES,
                    accuracy_multiplier: ACCURACY_BOOST,
                });
                self.emit(Event::BoostApplied(BoostApplied {
                    user: owner,
                    matches: BOOST_MATCHES,
                    accuracy_multiplier: ACCURACY_BOOST,
                }));
            }

            // Burn NFT
            self.owners.write(token_id, Zeroable::zero());
            self.token_levels.write(token_id, 0);
            self.token_uris.write(token_id, 0);
            self.token_expirations.write(token_id, 0);
            self.balances.write(owner, self.balances.read(owner) - 1.into());
            let lease = self.leases.read(token_id);
            if lease.lessee.is_non_zero() {
                self.leases.write(token_id, Lease { lessee: Zeroable::zero(), expiry: 0 });
                self.emit(Event::LeaseEnded(LeaseEnded {
                    token_id,
                    lessee: lease.lessee,
                }));
            }

            self.emit(Event::NFTBurned(NFTBurned {
                token_id,
                owner,
            }));
        }

        // Helper function to simulate a match and reduce boost matches
        fn play_match(ref self: ContractState, user: ContractAddress) {
            let mut boost = self.boost_status.read(user);
            if boost.matches_remaining > 0 {
                boost.matches_remaining -= 1;
                if boost.matches_remaining == 0 {
                    boost.accuracy_multiplier = 100; // Reset to 100% (no boost)
                }
                self.boost_status.write(user, boost);
            }
        }

        // Getter for boost status
        fn get_boost_status(self: @ContractState, user: ContractAddress) -> BoostStatus {
            self.boost_status.read(user)
        }

        // Getter for lease status
        fn get_lease_status(self: @ContractState, token_id: u256) -> Lease {
            self.leases.read(token_id)
        }

        // Getter for NFT expiration
        fn is_nft_valid(self: @ContractState, token_id: u256) -> bool {
            let expiry = self.token_expirations.read(token_id);
            expiry == 0 || get_block_timestamp() < expiry
        }
    }

    #[starknet::interface]
    trait INFTContract<TContractState> {
        fn create_nft(ref self: TContractState, name: felt252, symbol: felt252);
        fn mint_nft(ref self: TContractState, recipient: ContractAddress, level: u8, token_uri: felt252, is_ephemeral: bool) -> u256;
        fn lease_nft(ref self: TContractState, token_id: u256, lessee: ContractAddress, duration: u64);
        fn burn_nft(ref self: TContractState, token_id: u256);
        fn play_match(ref self: TContractState, user: ContractAddress);
        fn get_boost_status(self: @TContractState, user: ContractAddress) -> BoostStatus;
        fn get_lease_status(self: @TContractState, token_id: u256) -> Lease;
        fn is_nft_valid(self: @TContractState, token_id: u256) -> bool;
    }
}


#[cfg(test)]
mod tests {
    use starknet::ContractAddress;
    use starknet::contract_address_const;
    use starknet::get_block_timestamp;
    use snforge_std::{declare, ContractClassTrait, cheat_block_timestamp_global, CheatSpan};
    use super::NFTContract;
    use super::{INFTContractDispatcher, INFTContractDispatcherTrait, BoostStatus, Lease};

    fn setup() -> (ContractAddress, ContractAddress) {
        let contract = declare("NFTContract").unwrap();
        let admin = contract_address_const::<'admin'>();
        let (contract_address, _) = contract.deploy(@array!['NFT', 'NFT']).unwrap();
        (contract_address, admin)
    }

    #[test]
    fn test_create_nft() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };

        // Create NFT collection
        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        dispatcher.create_nft('NewNFT', 'NNFT');
        assert(dispatcher.get_name() == 'NewNFT', 'Name mismatch');
        assert(dispatcher.get_symbol() == 'NNFT', 'Symbol mismatch');
    }

    #[test]
    #[should_panic(expected: ('Only admin',))]
    fn test_create_nft_unauthorized() {
        let (contract_address, _) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let non_admin = contract_address_const::<'non_admin'>();
        
        cheat_caller_address_global(non_admin, CheatSpan::Indefinite);
        dispatcher.create_nft('NewNFT', 'NNFT');
    }

    #[test]
    fn test_mint_nft() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();

        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 3, 'uri://test', false);
        assert(token_id == 0, 'Token ID should be 0');
        assert(dispatcher.owner_of(token_id) == recipient, 'Owner mismatch');
        assert(dispatcher.get_token_level(token_id) == 3, 'Level mismatch');
        assert(dispatcher.get_token_uri(token_id) == 'uri://test', 'URI mismatch');
        assert(dispatcher.balance_of(recipient) == 1, 'Balance mismatch');
        assert(dispatcher.is_nft_valid(token_id), 'NFT should be valid');
    }

    #[test]
    fn test_mint_ephemeral_nft() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();

        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let start_time = get_block_timestamp();
        let token_id = dispatcher.mint_nft(recipient, 3, 'uri://full_moon_cue', true);
        assert(dispatcher.is_nft_valid(token_id), 'NFT should be valid');

        // Fast-forward 47 hours (still valid)
        cheat_block_timestamp_global(start_time + 47 * 3600);
        assert(dispatcher.is_nft_valid(token_id), 'NFT should still be valid');

        // Fast-forward to 49 hours (expired)
        cheat_block_timestamp_global(start_time + 49 * 3600);
        assert(!dispatcher.is_nft_valid(token_id), 'NFT should be expired');
    }

    #[test]
    fn test_lease_nft() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();
        let lessee = contract_address_const::<'lessee'>();

        // Mint NFT
        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 3, 'uri://test', false);

        // Lease NFT
        cheat_caller_address_global(recipient, CheatSpan::Indefinite);
        let duration = 24 * 3600; // 24 hours
        dispatcher.lease_nft(token_id, lessee, duration);

        let lease = dispatcher.get_lease_status(token_id);
        assert(lease.lessee == lessee, 'Lessee mismatch');
        assert(lease.expiry == get_block_timestamp() + duration, 'Expiry mismatch');
    }

    #[test]
    #[should_panic(expected: ('Only owner',))]
    fn test_lease_nft_unauthorized() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();
        let lessee = contract_address_const::<'lessee'>();
        let non_owner = contract_address_const::<'non_owner'>();

        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 3, 'uri://test', false);

        cheat_caller_address_global(non_owner, CheatSpan::Indefinite);
        dispatcher.lease_nft(token_id, lessee, 24 * 3600);
    }

    #[test]
    fn test_burn_nft_with_boost() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();

        // Mint low-level NFT (level 4)
        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 4, 'uri://test', false);

        // Burn NFT
        cheat_caller_address_global(recipient, CheatSpan::Indefinite);
        dispatcher.burn_nft(token_id);

        // Verify boost
        let boost = dispatcher.get_boost_status(recipient);
        assert(boost.matches_remaining == 3, 'Matches remaining mismatch');
        assert(boost.accuracy_multiplier == 110, 'Accuracy multiplier mismatch');

        // Verify NFT is burned
        assert(dispatcher.owner_of(token_id).is_zero(), 'NFT not burned');
        assert(dispatcher.balance_of(recipient) == 0, 'Balance not updated');

        // Simulate matches
        dispatcher.play_match(recipient);
        let boost = dispatcher.get_boost_status(recipient);
        assert(boost.matches_remaining == 2, 'Matches not decremented');

        dispatcher.play_match(recipient);
        dispatcher.play_match(recipient);
        let boost = dispatcher.get_boost_status(recipient);
        assert(boost.matches_remaining == 0, 'Boost not expired');
        assert(boost.accuracy_multiplier == 100, 'Boost not reset');
    }

    #[test]
    fn test_burn_nft_no_boost() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();

        // Mint high-level NFT (level 6)
        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 6, 'uri://test', false);

        // Burn NFT
        cheat_caller_address_global(recipient, CheatSpan::Indefinite);
        dispatcher.burn_nft(token_id);

        // Verify no boost applied
        let boost = dispatcher.get_boost_status(recipient);
        assert(boost.matches_remaining == 0, 'No boost should be applied');
        assert(boost.accuracy_multiplier == 100, 'Accuracy should be 100');
    }

    #[test]
    #[should_panic(expected: ('NFT expired',))]
    fn test_burn_expired_nft() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();

        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 3, 'uri://full_moon_cue', true);

        // Fast-forward past expiration
        cheat_block_timestamp_global(get_block_timestamp() + 49 * 3600);

        cheat_caller_address_global(recipient, CheatSpan::Indefinite);
        dispatcher.burn_nft(token_id);
    }

    #[test]
    fn test_lease_and_burn() {
        let (contract_address, admin) = setup();
        let dispatcher = INFTContractDispatcher { contract_address };
        let recipient = contract_address_const::<'recipient'>();
        let lessee = contract_address_const::<'lessee'>();

        // Mint NFT
        cheat_caller_address_global(admin, CheatSpan::Indefinite);
        let token_id = dispatcher.mint_nft(recipient, 3, 'uri://test', false);

        // Lease NFT
        cheat_caller_address_global(recipient, CheatSpan::Indefinite);
        dispatcher.lease_nft(token_id, lessee, 24 * 3600);

        // Burn NFT
        dispatcher.burn_nft(token_id);

        // Verify lease is terminated
        let lease = dispatcher.get_lease_status(token_id);
        assert(lease.lessee.is_zero(), 'Lease not terminated');
        assert(lease.expiry == 0, 'Lease expiry not reset');
    }
}
