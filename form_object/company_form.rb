# frozen_string_literal: true

class CompanyForm
  class FormNotSavedError < StandardError; end

  include ActiveModel::Model

  # @return [Company]
  attr_reader :company
  # @return [Admin]
  attr_reader :admin

  validate :validate_models

  def initialize(attributes = {})
    @company_id = attributes[:id]
    @company_params = attributes[:company]
    @admin_params = attributes[:admin]
    find_or_initialize_models
  end

  def save
    return false if invalid?

    Company.transaction do
      raise FormNotSavedError unless company.save && admin.save
    end
    invalidate_projects_cache

    true
  rescue FormNotSavedError => e
    handle_error(e)
  end

  private

  attr_reader :company_id, :company_params, :admin_params

  def handle_error(error)
    Rails.logger.error(error)
    errors.add(:base, 'Could not be saved')
    false
  end

  def validate_models
    [company, admin].each do |model|
      next if model.valid?

      model.errors.each do |attr, error|
        errors.add("#{model.class.name} #{attr}", error)
      end
    end
  end

  def find_or_initialize_models
    find_or_initialize_company
    find_or_initialize_admin
    find_or_initialize_disk_usage
  end

  def find_or_initialize_company
    @company = company_id.present? ? Company.find(company_id) : Company.new

    if company_params.present?
      company.assign_attributes(adjusted_company_params)
    else
      build_company_settings
    end
  end

  def find_or_initialize_admin
    @admin = company.admin || Admin.new(default_admin_params)
    return if admin_params.nil?

    admin.assign_attributes(adjusted_admin_params)
  end

  def default_admin_params
    {
      company: company,
      language: company.language
    }
  end

  def adjusted_company_params # rubocop:disable Metrics/AbcSize
    return if company_params.nil?

    @adjusted_company_params ||= company_params.tap do |hash|
      hash[:imap_settings_attributes]&.delete(:password) if hash.dig(:imap_settings_attributes, :password).blank?
      hash[:smtp_settings_attributes]&.delete(:password) if hash.dig(:smtp_settings_attributes, :password).blank?
      hash[:sms_settings_attributes]&.delete(:password) if hash.dig(:sms_settings_attributes, :password).blank?
    end
  end

  def adjusted_admin_params
    return if admin_params.nil?

    @adjusted_admin_params ||= admin_params.tap do |hash|
      if hash[:password] == ''
        hash.delete(:password)
        hash.delete(:password_confirmation)
      end
    end
  end

  def find_or_initialize_disk_usage
    company.build_disk_usage if company.disk_usage.nil?
  end

  def build_company_settings
    company.build_imap_settings if company.imap_settings.nil?
    company.build_smtp_settings if company.smtp_settings.nil?
    company.build_sms_settings if company.sms_settings.nil?
    company.build_media_drive_settings_with_defaults if company.media_drive_settings.nil?
    company.build_subscription if company.subscription.nil?
    company.first_or_build_two_factor_authentication_settings_with_defaults
    company.build_media_drive_storage_settings_with_defaults if company.media_drive_storage_settings.nil?
  end

  def invalidate_projects_cache
    return unless company.subscription.saved_change_to_attribute?(:available_modules)

    company.projects.update_all(updated_at: Time.current)
  end
end
