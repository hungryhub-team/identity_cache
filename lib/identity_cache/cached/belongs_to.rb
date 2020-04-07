# frozen_string_literal: true
module IdentityCache
  module Cached
    class BelongsTo < Association # :nodoc:
      attr_reader :records_variable_name

      def build
        reflection.active_record.class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
          def #{cached_accessor_name}
            association_klass = association(:#{name}).klass
            if association_klass.should_use_cache? && #{reflection.foreign_key}.present? && !association(:#{name}).loaded?
              if defined?(#{records_variable_name})
                #{records_variable_name}
              else
                #{records_variable_name} = association_klass.fetch_by_id(#{reflection.foreign_key})
              end
            else
              #{name}
            end
          end
        RUBY
      end

      def clear(record)
        if record.instance_variable_defined?(records_variable_name)
          record.remove_instance_variable(records_variable_name)
        end
      end

      def write(owner_record, associated_record)
        owner_record.instance_variable_set(records_variable_name, associated_record)
      end

      def fetch(records)
        fetch_async(LoadStrategy::Eager, records) { |associated_records| associated_records }
      end

      def fetch_async(load_strategy, records)
        if reflection.polymorphic?
          cache_keys_to_associated_ids = {}

          records.each do |owner_record|
            associated_id = owner_record.send(reflection.foreign_key)
            next unless associated_id && !owner_record.instance_variable_defined?(records_variable_name)
            associated_cache_key = Object.const_get(
              owner_record.send(reflection.foreign_type)
            ).cached_model.cached_primary_index
            unless cache_keys_to_associated_ids[associated_cache_key]
              cache_keys_to_associated_ids[associated_cache_key] = {}
            end
            cache_keys_to_associated_ids[associated_cache_key][associated_id] = owner_record
          end

          load_strategy.load_batch(cache_keys_to_associated_ids) do |associated_records_by_cache_key|
            batch_records = []
            associated_records_by_cache_key.each do |cache_key, associated_records|
              associated_records.keys.each do |id, associated_record|
                owner_record = cache_keys_to_associated_ids.fetch(cache_key).fetch(id)
                batch_records << owner_record
                write(owner_record, associated_record)
              end
            end

            yield batch_records
          end
        else
          ids_to_owner_record = records.each_with_object({}) do |owner_record, hash|
            associated_id = owner_record.send(reflection.foreign_key)
            if associated_id && !owner_record.instance_variable_defined?(records_variable_name)
              hash[associated_id] = owner_record
            end
          end

          load_strategy.load_multi(
            reflection.klass.cached_primary_index,
            ids_to_owner_record.keys
          ) do |associated_records_by_id|
            associated_records_by_id.each do |id, associated_record|
              owner_record = ids_to_owner_record.fetch(id)
              write(owner_record, associated_record)
            end

            yield associated_records_by_id.values.compact
          end
        end
      end

      def embedded_recursively?
        false
      end

      def embedded_by_reference?
        false
      end
    end
  end
end
