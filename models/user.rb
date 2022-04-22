class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  # ------------ Relationships ------------
  belongs_to :user_type, class_name: "Constant", foreign_key: "user_type_id", optional: true
  has_one :access_token
  has_and_belongs_to_many :roles
  has_many :user_logins
  has_many :drug_pack_actions
  has_many :latest_drug_pack_actions
  has_many :itineraries, class_name: "Itinerary", foreign_key: "driver_id"
  has_many :itinerary_actions

  # ------------ Validations ------------
  scope :without_deleted, -> { where(deleted_at: nil) }

  # ------------ Triggers ------------
  after_create :generate_access_token

  # ------------ Helpers ------------
  # store_accessor :meta, :is_loaded
  include Searchable::User
  include PgSearch
  pg_search_scope :search_by_q, against: :name, using: { tsearch: { prefix: true } }

  paginates_per 20
  max_paginates_per 100

  # ------------ Instance Methods ------------
  store_accessor :meta, :is_depot_personnel, :pw_token, :checkout_general_only, :is_admin
  delegate :token, to: :access_token

  pg_search_scope :search_by_q, against: :name, using: { tsearch: { prefix: true } }

  # Return the current DrugPacks checked out by the User
  def current_drug_packs
    ::Drug
      .joins(latest_drug_pack_actions: :action)
      .where.not(latest_drug_pack_actions: {pack_action_id: nil })
      .where(
        latest_drug_pack_actions: { user_id: id },
        constants: { name: ["station_param_check_out", "station_param_submit_duf"] }
      )
  end

  def active_itinerary
    itineraries.order(created_at: :desc).find_by(is_active: true) || itineraries.where("updated_at > ?", (Time.now - 6.hours)).order(updated_at: :desc).first
  end

  def permissions
    return { can_audit: false, can_sbd: false, can_audit_locker: false, can_audit_sbd: false, can_confirm_delivery: false, can_checkout_sbd: true } if user_type.blank?
    user_type.permissions || { can_audit: false, can_sbd: false, can_audit_locker: false, can_audit_sbd: false, can_confirm_delivery: false, can_checkout_sbd: true }
  end

  def max_packs

    # The below code is an attempt to remove the restraint requires this to be updated each time a pack_module is added
    results = user_type&.max_packs || {}
    Pack.select(:name).each_with_object(results) do |pack, res|
      res[pack.formatted_name] ||= name.downcase == "paramedic" ? 3 : 1
    end
  end

  def reset_pin
    update(pin: rand(1000..9999).to_s, has_temp_pin: true)
    Mailman.reset_pin_email(self).deliver
  end

  def pack_access
    "#{checkout_general_only ? "G." : "G.P."}#{user_type_id.present? ? "A." : ""}"
  end

  def last_login
    user_logins.last.try(:login_time).try(:to_i) || "Never."
  end

  # ------------ Class Methods ------------

  def self.import_esr_data(file)
    users_to_import = CSV.read(file, headers: true).to_a
    users_to_import.shift

    users_to_import.each_with_index do |csv_row, index|
      p "Parsed #{index} rows of #{users_to_import.size} ..." if index % 100 == 0
      if csv_row[7] == "0"
        user = find_or_create_by(personnel_no: csv_row[0])
        user.creator_id = 1
        user.name = "#{csv_row[1]} #{csv_row[2]}"
        user.email = csv_row[5].downcase if csv_row[5].present?
        user.checkout_general_only = csv_row[6] == "Pack"
        user.save!
      end
    end
  end

  # ------------ Private Methods ------------
  private

  def generate_access_token
    AccessToken.find_or_create_by(user_id: id)
  end
end
