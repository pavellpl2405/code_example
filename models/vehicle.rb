class Vehicle < ApplicationRecord
  # ------------ Relationships ------------
  has_many :itineraries
  belongs_to :status, class_name: "Constant", foreign_key: "status_id", optional: true

  # ------------ Validations ------------

  # ------------ Helpers ------------
  # store_accessor :meta, :is_loaded
  include Searchable::Vehicle
  include PgSearch

  paginates_per 50
  max_paginates_per 200

  # ------------ Instance Methods ------------

  pg_search_scope :search_by_q, against: :fleet_no, using: {tsearch: {prefix: true}}

  def current_contents
    current_itinerary
  end

  def current_itinerary(current_user = nil)
    @current_itinerary ||= if current_user.blank?
      itineraries.order(created_at: :desc).find_by(is_active: true) || itineraries.where("updated_at > ?", (Time.now - 6.hours)).order(updated_at: :desc).first
    else
      current_user.itineraries.order(created_at: :desc).find_by(is_active: true) || current_user.itineraries.where("updated_at > ?", (Time.now - 6.hours)).order(updated_at: :desc).first
    end
  end

  def loading(params, current_user)
    load_action = ::Constant.find_by(name: "NDA")
    itinerary_loading_action = ::Constant.find_by(name: "NDA")
    sbd_order_loading_state = ::Constant.sbd_order_states.find_by(name: "on_route")

    # Van must be prepped before loading the van
    raise NDA::Exceptions::InvalidRecord, "Van was not prepped. Please prep before continuing." unless current_itinerary(current_user)
    # No loading action is permitted after route has started (a station replenish was made)
    raise NDA::Exceptions::InvalidRecord, "Load was completed. Please continue replenishing stations." if current_itinerary(current_user).itinerary_actions.count > 1

    # Handle existing or new SBD Orders
    params[:station_drug_order_ids] ||= []
    if params.has_key? :new_orders
      ::StationDrugOrder.transaction do
        params[:new_orders].each do |order|
          sdo = ::StationDrugOrder.find_or_create_by(station_id: order[:station_id], order_no: order[:order_no])
          params[:station_order_ids] << sdo.id
        end
      end
    end
    # Update the `loaded_at` param for each loaded SBD Order
    ::StationDrugOrder.where(id: params[:station_order_ids]).update_all(loaded_at: Time.now, state_id: sbd_order_loading_state.id)

    if current_itinerary(current_user).itinerary_actions.count >= 1 && current_itinerary(current_user).itinerary_actions.order(created_at: :desc).first.action_id == itinerary_loading_action.id
      # There was another 'load' action just before this one.
      ila = current_itinerary(current_user).itinerary_actions.order(created_at: :desc).first
      ila.update(
        station_order_ids: (ila.station_order_ids << params[:station_order_ids]).flatten.compact.uniq,
        collected_blanket_no: ila.collected_blanket_no + params[:blanket_no],
        post_pickup: params[:post_pickup],
        post_dropoff: params[:post_dropoff]
      )
    else
      # Save itinerary vehicle loading action
      current_itinerary(current_user).itinerary_actions.create!(
        user_id: current_user.id,
        action_id: itinerary_loading_action.id,
        station_drug_order_ids: params[:station_drug_order_ids],
        collected_blanket_no: params[:blanket_no],
        post_pickup: params[:post_pickup],
        post_dropoff: params[:post_dropoff]
      )
    end

    # Update vehicle status to "loaded"
    update_attribute(:status_id, ::Constant.vehicle_statuses.find_by(name: "loaded").id)

    if params.has_key? :drug_packs
      ::PackAction.transaction do
        params[:drug_packs].each do |pack|
          ::PackAction.create!(
            user_id: current_user.id,
            action_id: load_action.id,
            pack_id: pack[:id],
            action_input_type: pack[:action_input_type],
            itinerary_id: current_itinerary(current_user).id
          )
        end
      end
    end
  end

  def update_loading(params, current_user)
    load_action = ::Constant.find_by(name: "NDA")
    itinerary_loading_action = ::Constant.find_by(name: "NDA")
    loading_action = current_itinerary(current_user).itinerary_actions.find_by(action_id: itinerary_loading_action.id)
    sbd_order_packed_state = ::Constant.sbd_order_states.find_by(name: "packed")
    sbd_order_loading_state = ::Constant.sbd_order_states.find_by(name: "on_route")

    if params.has_key? :drug_packs
      ::PackAction.transaction do
        # Destroy the previous loaded Drug Packs.
        dp_actions = ::PackAction.where(itinerary_id: current_itinerary(current_user).id, action_id: load_action.id)
        pack_ids = dp_actions.map(&:pack_id)
        dp_actions.update_all(deleted_at: Time.now)
        # Update the LatestDrugPackAction
        pack_ids_to_update = pack_ids - params[:drug_packs].map { |dp| dp[:id] }
        latest_dpa_to_update = ::LatestPackAction.where(drug_pack_id: pack_ids_to_update)
        prev_dp_actions = ::PackAction.select("DISTINCT ON (drug_pack_id) *").where(pack_id: pack_ids_to_update).order(:pack_id, id: :desc)
        latest_dpa_to_update.each do |ldpa|
          prev_dpa = prev_dp_actions.select { |x| x.drug_pack_id == ldpa.drug_pack_id }
          ldpa.update!(
              pack_action_id: prev_dpa.try(:id),
              station_id: prev_dpa.try(:station_id),
              action_id: prev_dpa.try(:action_id),
              user_id: prev_dpa.try(:user_id),
              itinerary_id: prev_dpa.try(:itinerary_id),
              itinerary_action_id: prev_dpa.try(:itinerary_action_id),
              station_locker_audit_id: prev_dpa.try(:station_locker_audit_id),
              created_at: (prev_dpa.try(:created_at) || DateTime.now.utc),
              updated_at: (prev_dpa.try(:created_at) || DateTime.now.utc)
          )
        end

        # Reload the Drug Packs received
        params[:packs].each do |drug_pack|
          ::PackAction.create!(
            user_id: current_user.id,
            action_id: load_action.id,
            pack_id: pack[:id],
            action_input_type: drug_pack[:action_input_type],
            itinerary_id: current_itinerary(current_user).id
          )
        end
      end
    end

    # Handle existing or new SBD Orders
    params[:station_order_ids] ||= []
    if params.has_key? :new_orders
      ::StationOrder.transaction do
        ::StationOrder.where(id: loading_action.station_order_ids).update_all(loaded_at: nil, state_id: sbd_order_packed_state.id)

        params[:new_orders].each do |order|
          sdo = ::StationDrugOrder.find_or_create_by(station_id: order[:station_id], order_no: order[:order_no])
          params[:station_order_ids] << sdo.id
        end
      end
    end
    ::StationOrder.where(id: params[:station_order_ids]).update_all(loaded_at: Time.now, state_id: sbd_order_loading_state.id)

    # Update vehicle status to "loaded"
    update_attribute(:status_id, ::Constant.vehicle_statuses.find_by(name: "loaded").id)

    # Update itinerary vehicle's params
    update_params = {
      station_order_ids: params[:station_order_ids],
      collected_blanket_no: params[:blanket_no],
      post_pickup: params[:post_pickup],
      post_dropoff: params[:post_dropoff]
    }
    update_params.delete_if { |k, v| v.blank? && v != false }
    loading_action.update(update_params)
  end

  def unloading(params, current_user)
    # If van is already unloaded, update_unloading method must be used
    unload_action = ::Constant.find_by(name: "NDA")
    itinerary_unloading_action = ::Constant.find_by(name: "NDA")

    # Check if there's a previous Unload action
    if current_itinerary(current_user).is_active == false && current_itinerary(current_user).auto_canceled != true
      prev_unload_action = current_itinerary(current_user).itinerary_actions.order(created_at: :desc).find_by(action_id: itinerary_unloading_action.id)
      # Soft delete all DrugPack actions from the previous Unload
      ::PackAction.transaction do
        ::PackAction.where(itinerary_action_id: prev_unload_action.id).map(&:destroy)
        prev_unload_action.destroy
      end
    end

    # Handle existing or new SBD Orders
    params[:station_order_ids] ||= []
    if params.has_key? :new_orders
      ::StationOrder.transaction do
        params[:new_orders].each do |order|
          sdo = ::StationOrder.find_or_create_by(station_id: order[:station_id], order_no: order[:order_no])
          params[:station_order_ids] << sdo.id
        end
      end
    end

    # Save itinerary vehicle unloading action (???)
    unload_itinerary_action = current_itinerary(current_user).itinerary_actions.create!(
      user_id: current_user.id,
      action_id: itinerary_unloading_action.id,
      station_order_ids: params[:station_order_ids],
      collected_blanket_no: params[:blanket_no],
      post_pickup: params[:post_pickup],
      post_dropoff: params[:post_dropoff],
      comment: params[:comment],
      prf_dropoff: params[:prf_dropoff],
      prf_pickup: params[:prf_pickup] || {}
    )

    ::PackAction.transaction do
      params[:packs].each do |pack|
        ::PackAction.create!(
          user_id: current_user.id,
          action_id: unload_action.id,
          pack_id: pack[:id],
          action_input_type: pack[:action_input_type],
          itinerary_id: current_itinerary(current_user).id,
          itinerary_action_id: unload_itinerary_action.id
        )
      end
    end

    # Mark itinerary as 'complete'
    itinerary = current_itinerary(current_user)
    itinerary.update_attribute(:is_active, false)
    # Update vehicle status to "available"
    update_attribute(:status_id, ::Constant.vehicle_statuses.find_by(name: "available").id)
    itinerary
  end


  # ------------ Class Methods ------------

  # ------------ Private Methods ------------
  private
end
