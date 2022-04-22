# frozen_string_literal: true

module HumanResources
  class JobAssignmentForm < HumanResources::ApplicationForm
    attr_accessor :title, :uuid, :business_partner_uuid, :users_uuids, :starts_at, :ends_at, :sections
    attr_reader :model

    validate :users_exist, if: -> { users_uuids.present? }
    validate :starts_at_ends_at_not_updated, :business_partner_id_not_changed, if: -> { model.persisted? }
    with_options if: :business_partner_module_active? do
      validates :business_partner_uuid, presence: true
      validate :business_partner_exists, if: -> { business_partner_uuid.present? }
    end

    def initialize(attributes = {}, model:)
      @model = model
      super(attributes)
      @model.assign_attributes(model_attributes)
    end

    private

    delegate :company, to: :model

    def model_attributes
      job_assignment_attributes.tap do |attrs|
        attrs[:business_partner_id] = business_partner&.id if business_partner_module_active?
        attrs[:user_job_assignments] = users_for_job_assignment unless users_uuids.nil?
        attrs[:sections_attributes] = sections_for_job_assignment unless sections.nil?
      end.compact
    end

    def job_assignment_attributes
      {
        title: title,
        uuid: uuid,
        starts_at: HumanResources::TimeParser.parse_starts_at(starts_at),
        ends_at: HumanResources::TimeParser.parse_ends_at(ends_at)
      }
    end

    def users_for_job_assignment
      users.map do |user|
        next model.user_job_assignments.build(user: user) if model.new_record?

        HumanResources::UserJobAssignment.find_or_initialize_by(job_assignment: model, user: user)
      end
    end

    def sections_for_job_assignment
      HumanResources::Builders::JobAssignmentSectionsBuilder.new(
        job_assignment: model,
        sections_data: sections
      ).build
    end

    def users
      # since we have no `users.uuid` yet we use `users.email` temporary
      @users ||= company.users.where(email: users_uuids)
    end

    def business_partner
      @business_partner ||= company.business_partners.find_by(uuid: business_partner_uuid)
    end

    def users_exist
      existing_user_emails = users.map(&:email)
      emails_not_found = users_uuids.delete_if { |email| existing_user_emails.include?(email) }
      return if emails_not_found.empty?

      errors.add(:base, :emails_not_found, emails: emails_not_found.join(', '))
    end

    def starts_at_ends_at_not_updated
      return if !model.will_save_change_to_starts_at? && !model.will_save_change_to_ends_at?

      errors.add(:base, :dates_not_available_to_update)
    end

    def business_partner_id_not_changed
      return if model.business_partner_id_was.nil?
      return unless model.will_save_change_to_business_partner_id?

      errors.add(:base, :business_partner_not_available_to_change)
    end

    def business_partner_exists
      return if business_partner.present?

      errors.add(:business_partner_uuid, :absent_relation,
                 relation: "Business Partner (UUID: #{business_partner_uuid})")
    end

    def business_partner_module_active?
      @business_partner_module_active ||= company.module_available?('business_partners')
    end
  end
end
