class DeletedDossier < ApplicationRecord
  belongs_to :procedure

  validates :dossier_id, uniqueness: true

  enum reason: {
    user_request:      'user_request',
    manager_request:   'manager_request',
    user_removed:      'user_removed',
    procedure_removed: 'procedure_removed',
    expired:           'expired'
  }

  def self.create_from_dossier(dossier, reason)
    create!(
      reason: reasons.fetch(reason),
      dossier_id: dossier.id,
      procedure: dossier.procedure,
      state: dossier.state,
      deleted_at: Time.zone.now
    )
  end
end
