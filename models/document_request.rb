module NDA
  class DocumentRequest < NDA::Base
    include AASM

    PAGINATE_ITEMS_PER_PAGE = 30

    belongs_to :requested_user, class_name: "User", foreign_key: :requested_user_id,
               inverse_of: :document_requests, optional: true
    belongs_to :internal_employee, class_name: 'InternalEmployee', foreign_key: :reviewer_id, optional: true
    has_many :attachments, class_name: 'DocumentRequestAttachment', dependent: :destroy
    belongs_to :document_type, class_name: "DocumentRequestType", foreign_key: :document_type_id,
               inverse_of: :document_requests, optional: true
    # Relations for search functionality
    has_one :requested_am_user, -> { readonly }, through: :requested_user, source: :am_user, class_name: Ikh.am_user_class_name
    has_one :internal_employee_am_user, -> { readonly }, through: :internal_employee, source: :am_user, class_name: Ikh.am_user_class_name

    accepts_nested_attributes_for  :attachments

    validates :requested_user_id, presence: true
    validates :subject, presence: true
    validates :message, presence: true
    validates :document_type, presence: true
    validates :time_job_task_id, uniqueness: {allow_blank: true}

    scope :approved, -> { where(aasm_state: ['accepted', 'otherwise_done'] ) }
    scope :unfetched, -> { where(fetched: false) }
    scope :not_done, -> { where.not(aasm_state: 'otherwise_done') }
    scope :requested_by_ems, -> { where(aasm_state: ['requested', 'declined']) }
    scope :not_reviewed, ->  { where(aasm_state: ['requested', 'processed'] )  }
    scope :filter_by_status, -> (params) { params[:status] == "not_reviewed" ? not_reviewed : where(aasm_state: params[:status]) if params[:status]  }
    scope :search_text, -> (params) { ransack(search_text_cont: params[:search_text])
                                      .result.includes(:requested_user, :internal_employee, :requested_am_user, :internal_employee_am_user) if params[:search_text]  }
    scope :paginated, -> (params) do
      break if params[:page].blank?
      per_page = params[:per_page].to_i
      per_page = PAGINATE_ITEMS_PER_PAGE if per_page.zero?

      page(params[:page].to_i).per(per_page)
    end

    after_create :start_user_reminder

    ransack_alias :search_text, "NDA"

    aasm do
      state :requested, initial: true
      state :processed # FIXME: `processed` means `ready_to_review`
      state :accepted
      state :declined
      state :otherwise_done

      event :process do
        transitions from:  [:requested, :declined], to: :processed
      end

      event :accept, after: :send_user_chage_state_notification do
        transitions from: :processed, to: :accepted
      end

      event :decline, before: :clear_processed_request, after: [:start_user_reminder, :send_user_chage_state_notification] do
        transitions from: :processed, to: :declined
      end

      event :otherwise_end, after: :send_user_chage_state_notification do
        transitions to: :otherwise_done
      end
    end

    def self.find_or_initialize_from_json(params)
      document_request = self.find_or_initialize_by(id: params.delete(:id))
      document_request.attributes = params
      document_request
    end

    def reviewer=user
      self.reviewer_id = user.id
      self.reviewed_at = Time.now
    end

    protected

    def clear_processed_request
      self.attachments.destroy_all
      self.requested_user_notes = nil
      self.save
    end

    def send_user_chage_state_notification()
      subject =  I18n.t("NDA#{self.NDA}_subject")
      message =  I18n.t("NDA#{self.NDA}_text", rejected_reason: self.reviewer_notes)

      send_push_notification(subject, message)
      send_client_email(subject, message) if self.requested_user.is_a?(NDA::NDA)
    end


    def send_push_notification(subject, text)
      am_user = self.requested_user.am_user
      company = am_user.company

      push_notification_data = {
          company: company,
          recipients_type: 'User',
          recipients_info: [ am_user.id],
          subject: subject,
          text: text,
      }
      NDA.push_notification_class.create(push_notification_data)
    end

    def send_client_email(subject, text)
      am_user = self.requested_user.am_user
      recipient = am_user.try(:email)
      sender = am_user.company.try(:sender_email)
      return if sender.blank? || recipient.blank?
      NDA::NDA.document_request_email(sender, recipient, subject, text).deliver_later
    end

    private

    def start_user_reminder
      return if time_job_task_id.blank?

      DocumentRequestReminderJob.set(wait: delay).perform_later(id, aasm_state, 1)
    end
  end
end
