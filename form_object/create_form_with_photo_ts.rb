# frozen_string_literal: true

module HumanResources
  module InternalApi
    module ActivityReports
      class CreateFormWithPhotoTs < HumanResources::ApplicationForm
        class FindAssignedJobAssignmentQuery
          def initialize(id:, user:)
            @id = id
            @user = user
          end

          def execute
            @user.assigned_job_assignments.find_by(hr_job_assignments: { id: @id, company_id: @user.company_id })
          end
        end

        attr_accessor :job_assignment_id, :created_by, :activity, :creator_time_zone, :year,
                      :calendar_period_number, :attachments, :accept

        validate :validate_creator_assigned
        validate :validate_signature_exists, if: -> { time_tracking_settings.creator_signature_required? }
        validate :validate_release_form
        validate :validate_photo_ts_allowed
        validate :validate_empty_photo_ts

        def save
          return false if invalid?

          model.transaction do
            model.save!(validate: false)
            release_form.save!(propagate_ar_exception: true)
            model.verify_signature!
          end
        rescue StandardError => e
          log_error(e)
          false
        end

        # @return [HumanResources::WeeklyReport]
        def model
          @model ||= HumanResources::WeeklyReport.new(weekly_report_attributes)
        end

        private

        delegate :first_week_day, to: :time_tracking_settings
        delegate :date_range, to: :job_assignment, allow_nil: true, prefix: true

        def weekly_report_attributes
          {
            job_assignment_id: job_assignment_id,
            created_by: created_by,
            activity: activity,
            creator_time_zone: creator_time_zone,
            year: year,
            calendar_period_number: calendar_period_number.to_i,
            photo_ts: photo_ts,
            signature: signature
          }.compact
        end

        def release_form
          @release_form ||= begin
                              if accept.present?
                                HumanResources::InternalApi::ActivityReports::ReleaseForm.new(**release_form_attributes)
                              else
                                HumanResources::NullForm.new
                              end
                            end
        end

        def release_form_attributes
          accept.symbolize_keys.merge!(
            activity_report: model,
            company_id: created_by.company_id,
            release_type: 'accept'
          )
        end

        def signature
          base64_signature = attachments&.fetch(:base64_signature, nil)
          return if base64_signature.nil?

          HumanResources::Attachment.new(base64_attachment: base64_signature, company_id: created_by.company_id)
        end

        def photo_ts
          base64_photo_ts = attachments&.fetch(:base64_photo_ts, nil)
          return if base64_photo_ts.nil?

          HumanResources::Attachment.new(base64_attachment: base64_photo_ts, company_id: created_by.company_id)
        end

        def job_assignment
          @job_assignment ||= FindAssignedJobAssignmentQuery.new(id: job_assignment_id, user: created_by).execute
        end

        def validate_creator_assigned
          return if job_assignment.present?

          errors.add(:base, :user_not_assigned)
        end

        def validate_signature_exists
          errors.add(:attachments, :blank) if signature.nil?
        end

        def validate_accept_exists
          errors.add(:accept, :blank) if accept.nil?
        end

        def validate_release_form
          errors.merge!(release_form.errors) if release_form.invalid?
        end

        def validate_empty_photo_ts
          return if photo_ts.present?

          errors.add(:base, :empty_photo_ts)
        end

        def time_tracking_settings
          @time_tracking_settings ||=
            created_by.company.hr_time_tracking_settings || created_by.company.build_hr_time_tracking_settings
        end

        def validate_photo_ts_allowed
          return if time_tracking_settings.photo_ts_allowed?

          errors.add(:base, :photo_ts_not_allowed)
        end

        def requires_legal_requirement_validation?
          time_tracking_settings.legal_requirement_validation == 'hard_rejection_validation'
        end
      end
    end
  end
end

