# frozen_string_literal: true

class TrialRegistrationForm
  class FormNotSavedError < StandardError; end

  include ActiveModel::Model

  SALUTATIONS = %w(Mr. Mrs. Herr Frau).freeze
  DEFAULT_LANGUAGE = 'German'
  DEFAULT_COMPANY_CREATOR = 'API'

  attr_accessor :salutation, :first_name, :last_name, :company_name, :email, :password, :password_confirmation,
                :phone, :data_privacy, :language, :receive_notifications, :created_by

  validates :first_name, :company_name, :data_privacy, presence: true
  validates :salutation, inclusion: { in: SALUTATIONS }
  validates :data_privacy, acceptance: true
  validate :validate_models

  def initialize(attributes = {})
    super
    @language ||= DEFAULT_LANGUAGE
    @created_by ||= DEFAULT_COMPANY_CREATOR
    build_models
  end

  def save
    return false if invalid?

    Company.transaction do
      raise FormNotSavedError unless company.save && admin.save
    end

    send_activation_email
    copy_default_projects
    register_company_and_admin_on_hubspot
    schedule_activation_reminder
    true
  rescue FormNotSavedError
    false
  end

  def persisted?
    company.persisted? && admin.persisted?
  end

  def self.app_codes_to_copy
    DEFAULT_PROJECTS_APP_CODES.fetch(Rails.env.to_sym, [])
  end

  private

  attr_reader :admin, :company

  def build_models
    @company = TrialCompany.new(company_attributes)
    @company.build_disk_usage
    @admin = Admin.new(admin_attributes)
  end

  def validate_models
    validate_company
    validate_admin
  end

  def validate_company
    return if company.valid?

    company.errors.each do |attribute, error|
      attribute = :company_name if attribute == :name
      errors.add(attribute, error)
    end
  end

  def validate_admin
    return if admin.valid?

    admin.errors.each do |attribute, error|
      attribute = :last_name if attribute == :name
      errors.add(attribute, error)
    end
  end

  def company_attributes
    @company_attributes ||= {
      name: company_name,
      time_zone: 'NDA',
      language: language,
      created_by: created_by,
      subscription_attributes: {
        plan: trial_subscription_plan,
        status: 'trial'
      }
    }
  end

  # rubocop:disable Metrics/MethodLength
  def admin_attributes
    @admin_attributes ||= {
      company: company,
      email: email,
      password: password,
      password_confirmation: password_confirmation,
      salutation: salutation,
      first_name: first_name,
      name: last_name,
      phone: phone,
      language: language,
      accepted_privacy_policy: true
    }
  end

  def trial_subscription_plan
    @trial_subscription_plan ||= SubscriptionPlan.find_by!(name: 'Trial')
  end

  def send_activation_email
    ClientMailer.activation_email(admin).deliver_now
  end

  def copy_default_projects
    self.class.app_codes_to_copy.each do |app_code|
      app_code = AppCode.find_by(code: app_code)
      next if app_code.nil?

      copy = NDA::ProjectCopyService
             .build(app_code.project, destination_company: company, creator_id: admin.id)
             .execute
      create_auto_deployable_app_code_for(copy.project) if copy.present?
    end
  end

  handle_asynchronously :copy_default_projects

  def create_auto_deployable_app_code_for(project)
    app_code = project.codes.build(
      name: project.name,
      auto_deployment: true,
      deploy_immediately: true,
      selected_users: [admin.id],
      online: false
    )
    app_code.generate_code
    app_code.save
  end

  def register_company_and_admin_on_hubspot
    NDA.new(company, admin).register_company_and_user
  end

  def schedule_activation_reminder
    AccountActivationReminderJob.perform_later(company.id)
  end
end
