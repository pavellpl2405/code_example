class Workstation < ApplicationRecord
  # ------------ Relationships ------------
  belongs_to :workstation_type, class_name: "Constant", foreign_key: "replenish_workstation_type_id"
  has_many :workstation_audits
  has_many :workstation_transactions

  # ------------ Validations ------------

  # ------------ Helpers ------------
  store_accessor :meta, :audited_by, :audited_at
  include Searchable::Workstation
  include PgSearch

  paginates_per 50
  max_paginates_per 200

  scope :without_deleted, -> { where(deleted_at: [nil, ""]) }


  def update_associated_device_id(user, device_id)
    raise NDA::Exceptions::InvalidRecord, "Device ID missing." unless device_id

    if associated_device_id
      if NDA.enabled?("Workstation stealing") && get_latest_audit && get_latest_audit.created_at < Time.now.beginning_of_day
        # noop
      else
        raise NDA::Exceptions::InvalidRecord, "Workstation already associated to another device. Please contact your manager."
      end
    end
    workstation = ::Workstation.find_by(associated_device_id: device_id)
    update(associated_device_id: device_id)
    workstation.update(associated_device_id: nil) if workstation.present?
    # trigger email to manager
    Mailman.change_workstation_associated_device_id(user, name).deliver
  end

  # audit the Workstation's inventory
  def audit(drug_list, current_user, comment = "")
    # search for the previous transaction for that BatchID and store the quantity_delta for it.
    batch_quantities = {}
    drug_list.each do |drug|
      drug[:batches].each do |batch|
        batch_no = if batch.has_key?(:is_new) && batch[:is_new] == true # Need to create a new Batch for the given drug

          new_batch = ::Batch.find_or_create_by drug_id: drug[:id], batch_no: batch[:batch_no], expiry_date: Time.at(batch[:expiry_date])
          new_batch.id
        else
          batch[:id]
        end
        batch_quantities[batch_no] = batch[:quantity]
      end
    end

    changes = get_inventory_changes(batch_quantities.map { |k, v| [k.to_s, v] }.to_h)

    latest_audit = ::Workstation.create!(
      auditor_id: current_user.id,
      replenish_workstation_id: id,
      comment: comment,
      batch_quantities: batch_quantities,
      inventory_changes: changes
    )

    update(audited_by: current_user.id, audited_at: Time.now)
    # get Drug & Batch details for the email
    detailed_changes = []
    batches = ::Batch.includes(:drug).where(id: (changes.try(:keys) || []))
    batches.map do |b|
      detailed_changes.push({batch: b.batch_no, expiry: b.expiry_date.to_s, drug: b.drug.try(:name), change: changes[b.id.to_s].to_s})
    end
    # trigger email to manager
    Mailman.replenish_workstation_audit_changes(current_user, detailed_changes, name).deliver
    # return the audit created
    latest_audit
  end

  def move_inventory(params, current_user)
    transaction_type_id = ::Constant.workstn_transaction_types.find_by(name: "move").id
    dest_workstation = nil
    # cannot move inventory to a checking station
    if ::Workstation.find(params[:dest_workstation_id]).replenish_workstation_type.name != "packing"
      raise NDA::Exceptions::InvalidRecord, "Can only move inventory to packing station."
    end
    # create 2 transactions. One for debiting the current workstation, one for crediting the destination
    ::WorkstationTransaction.transaction do
      dest_workstation = ::Workstation.find(params[:dest_workstation_id])

      transaction_source = ::WorkstationTransaction.create!(
        user_id: current_user.id,
        transaction_type_id: transaction_type_id,
        workstation_id: id,
        workstation_audit_id: get_latest_audit.try(:id),
        drug_id: params[:id],
        batch_id: params[:batch_id],
        quantity: (0 - params[:quantity]),
        comment: params[:comment],
        linked_rw_name: dest_workstation.name
      )

      transaction_dest = ::WorkstationTransaction.create!(
        user_id: current_user.id,
        transaction_type_id: transaction_type_id,
        workstation_id: params[:dest_workstation_id],
        workstation_audit_id: dest_workstation.get_latest_audit.try(:id),
        drug_id: params[:id],
        batch_id: params[:batch_id],
        quantity: params[:quantity],
        comment: params[:comment],
        linked_rw_name: name,
        linked_transaction_id: transaction_source.id
      )

      transaction_source.update_attribute(:linked_transaction_id, transaction_dest.id)
    end

    # create & send email to LAS Depot manager with details about the Inventory Movement
    batch = ::Batch.includes(:drug).find(params[:batch_id])
    Mailman.workstation_move_inventory(current_user, name, dest_workstation.name, batch, batch.drug, params[:quantity], params[:comment]).deliver
  end

  def get_latest_audit
    workstation_audits.order(id: :desc).first
  end

  def get_latest_efin_transaction
    workstation_transactions.where(transaction_type_id: ::Constant.workstn_transaction_types.find_by(name: "efin_import")).order(id: :desc).first
  end

  def get_current_quantity_for_batch(batch_id)
    last_audit = get_latest_audit
    return 0 unless last_audit
    return last_audit.batch_quantities[batch_id.to_s] || 0 if last_audit.workstation_transactions.where(batch_id: batch_id).count == 0
    last_transaction = last_audit.transactions.where(batch_id: batch_id).last
    last_transaction.quantity
  end

  def get_inventory_batch_ids
    last_audit = get_latest_audit
    return [] unless last_audit
    (last_audit.batch_quantities.keys + last_audit.workstation_transactions.distinct.pluck(:batch_id)).map(&:to_i).uniq
  end

  def get_inventory
    inventory = {}
    last_audit = get_latest_audit
    return [] if last_audit.nil? || !last_audit.present?
    # return [] unless last_audit.batch_quantities.keys

    ::WorkstationTransaction.where(id: last_audit.workstation_transactions.group(:batch_id).pluck("max(id)")).map { |x| inventory[x.batch_id.to_s] = (x.running_total || 0) }
    full_inventory = last_audit.batch_quantities.merge(inventory)
    full_inventory.delete_if { |_, v| v <= 0 }
  end

  def get_inventory_changes(batch_quantities)
    changes = {}
    inventory = get_inventory
    return batch_quantities if inventory.empty?
    ((inventory.try(:keys) || []) + batch_quantities.keys).uniq.map { |t| changes[t] = ((batch_quantities[t] || 0) - (inventory[t] || 0)) if batch_quantities[t] != inventory[t] }
    changes
  end

  private
end
