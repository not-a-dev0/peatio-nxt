# encoding: UTF-8
# frozen_string_literal: true

module BlockchainService
  class Nxt < Peatio::BlockchainService::Base
    # Rough number of blocks per hour for Nxt is 6.
    def process_blockchain(blocks_limit: 6, force: false)
      latest_block = client.latest_block_number

      # Don't start process if we didn't receive new blocks.
      if blockchain.height + blockchain.min_confirmations >= latest_block && !force
        Rails.logger.info { "Skip synchronization. No new blocks detected height: #{blockchain.height}, latest_block: #{latest_block}" }
        fetch_unconfirmed_deposits
        return
      end

      from_block   = blockchain.height || 0
      to_block     = [latest_block, from_block + blocks_limit].min

      (from_block..to_block).each do |block_id|
        Rails.logger.info { "Started processing #{blockchain.key} block number #{block_id}." }

        block_hash = client.get_block_hash(block_id)
        next if block_hash.blank?

        block_json = client.get_block(block_hash)
        next if block_json.blank?

        block_data = { id: block_id }
        block_data[:deposits]    = build_deposits(block_json, block_id)
        block_data[:withdrawals] = build_withdrawals(block_json, block_id)

        save_block(block_data, latest_block)

        # process phased txns
        process_phasing_txns

        Rails.logger.info { "Finished processing #{blockchain.key} block number #{block_id}." }
      end
    rescue => e
      report_exception(e)
      Rails.logger.info { "Exception was raised during block processing." }
    end

    protected

    def update_or_create_deposits!(deposits)
      deposits.each do |deposit_hash|
        # If deposit doesn't exist create it.
        deposit = Deposits::Coin
                      .where(currency: currencies)
                      .find_or_create_by!(deposit_hash.slice(:txid)) do |deposit|
          deposit.assign_attributes(deposit_hash.except(:options))
        end

        deposit.update_column(:block_number, deposit_hash.fetch(:block_number))

        if deposit.confirmations >= blockchain.min_confirmations
          if deposit_hash[:options][:phased]
            deposit.pending!
          else
            deposit.accept!
            deposit.collect!
          end
        end
      end
    end

    private

    def build_deposits(block_json, block_id)
      block_json
          .fetch('transactions')
          .each_with_object([]) do |tx, deposits|

        next if client.invalid_transaction?(tx) # skip if invalid transaction

        payment_addresses_where(address: client.to_address(tx)) do |payment_address|

          deposit_txs = client.build_transaction(tx, block_id, payment_address.currency)

          deposit_txs.fetch(:entries).each_with_index do |entry, i|

            if entry[:amount] <= payment_address.currency.min_deposit_amount
              # Currently we just skip small deposits. Custom behavior will be implemented later.
              Rails.logger.info do  "Skipped deposit with txid: #{deposit_txs[:id]} with amount: #{entry[:amount]}"\
                                   " from #{entry[:address]} in block number #{deposit_txs[:block_number]}"
              end
              next
            end

            deposits << { txid:           deposit_txs[:id],
                          address:        entry[:address],
                          amount:         entry[:amount],
                          member:         payment_address.account.member,
                          currency:       payment_address.currency,
                          txout:          i,
                          block_number:   deposit_txs[:block_number],
                          options:        deposit_txs[:options]
                        }
          end
        end
      end
    end

    def build_withdrawals(block_json, block_id)
      block_json
          .fetch('transactions')
          .each_with_object([]) do |tx, withdrawals|

        next if client.invalid_transaction?(tx) # skip if invalid transaction

        Withdraws::Coin
            .where(currency: currencies)
            .where(txid: client.normalize_txid(tx.fetch('transaction')))
            .each do |withdraw|

          withdraw_txs = client.build_transaction(tx, block_id, withdraw.currency)
          withdraw_txs.fetch(:entries).each do |entry|
            withdrawals << {  txid:           withdraw_txs[:id],
                              rid:            entry[:address],
                              amount:         entry[:amount],
                              block_number:   withdraw_txs[:block_number] }
          end
        end
      end
    end

    def fetch_unconfirmed_deposits(block_json = {})
      Rails.logger.info { "Processing unconfirmed deposits." }
      txns = client.get_unconfirmed_txns

      # Read processed mempool tx ids because we can skip them.
      processed = Rails.cache.read("processed_#{self.class.name.underscore}_mempool_txids") || []

      # Skip processed txs.
      block_json.merge!('transactions' => txns - processed)
      deposits = build_deposits(block_json, nil)
      update_or_create_deposits!(deposits)

      # Store processed tx ids from mempool.
      Rails.cache.write("processed_#{self.class.name.underscore}_mempool_txids", txns)
    end

    def process_phasing_txns
      Deposits::Coin.where(currency: currencies) \
                    .pending.each do |deposit|

        # approved = true, false or nil
        approved = client.get_phasing_poll(deposit.txid)

        case approved
        when true
          deposit.accept!
          deposit.collect!
        when false
          deposit.reject!
        else
          next
        end
      end
    end
  end
end


