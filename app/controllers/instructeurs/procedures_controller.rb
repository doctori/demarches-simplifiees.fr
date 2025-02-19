module Instructeurs
  class ProceduresController < InstructeurController
    before_action :ensure_ownership!, except: [:index]

    ITEMS_PER_PAGE = 25

    def index
      @procedures = current_instructeur
        .procedures
        .kept
        .with_attached_logo
        .includes(:defaut_groupe_instructeur)
        .order(closed_at: :desc, unpublished_at: :desc, published_at: :desc, created_at: :desc)

      dossiers = current_instructeur.dossiers.joins(:groupe_instructeur)
      @dossiers_count_per_procedure = dossiers.all_state.group('groupe_instructeurs.procedure_id').reorder(nil).count
      @dossiers_a_suivre_count_per_procedure = dossiers.without_followers.en_cours.group('groupe_instructeurs.procedure_id').reorder(nil).count
      @dossiers_archived_count_per_procedure = dossiers.archived.group('groupe_instructeurs.procedure_id').count
      @dossiers_termines_count_per_procedure = dossiers.termine.group('groupe_instructeurs.procedure_id').reorder(nil).count

      groupe_ids = current_instructeur.groupe_instructeurs.pluck(:id)

      @followed_dossiers_count_per_procedure = current_instructeur
        .followed_dossiers
        .joins(:groupe_instructeur)
        .en_cours
        .where(groupe_instructeur_id: groupe_ids)
        .group('groupe_instructeurs.procedure_id')
        .reorder(nil)
        .count

      @all_dossiers_counts = {
        'à suivre' => @dossiers_a_suivre_count_per_procedure.sum { |_, v| v },
        'suivis' => @followed_dossiers_count_per_procedure.sum { |_, v| v },
        'traités' => @dossiers_termines_count_per_procedure.sum { |_, v| v },
        'dossiers' => @dossiers_count_per_procedure.sum { |_, v| v },
        'archivés' => @dossiers_archived_count_per_procedure.sum { |_, v| v }
      }

      @procedure_ids_en_cours_with_notifications = current_instructeur.procedure_ids_with_notifications(:en_cours)
      @procedure_ids_termines_with_notifications = current_instructeur.procedure_ids_with_notifications(:termine)
    end

    def show
      @procedure = procedure
      # Technically, procedure_presentation already sets the attribute.
      # Setting it here to make clear that it is used by the view
      @procedure_presentation = procedure_presentation

      @current_filters = current_filters
      @displayed_fields_options, @displayed_fields_selected = procedure_presentation.displayed_fields_for_select

      @a_suivre_count, @suivis_count, @traites_count, @tous_count, @archives_count = current_instructeur
        .dossiers_count_summary(groupe_instructeur_ids)
        .fetch_values('a_suivre', 'suivis', 'traites', 'tous', 'archives')

      dossiers_visibles = Dossier
        .where(groupe_instructeur_id: groupe_instructeur_ids)

      @a_suivre_dossiers = dossiers_visibles
        .without_followers
        .en_cours

      @followed_dossiers = current_instructeur
        .followed_dossiers
        .where(groupe_instructeur_id: groupe_instructeur_ids)
        .en_cours

      @followed_dossiers_id = @followed_dossiers.pluck(:id)

      @termines_dossiers = dossiers_visibles.termine
      @all_state_dossiers = dossiers_visibles.all_state
      @archived_dossiers = dossiers_visibles.archived

      @dossiers = case statut
      when 'a-suivre'
        dossiers_count = @a_suivre_count
        @a_suivre_dossiers
      when 'suivis'
        dossiers_count = @suivis_count
        @followed_dossiers
      when 'traites'
        dossiers_count = @traites_count
        @termines_dossiers
      when 'tous'
        dossiers_count = @tous_count
        @all_state_dossiers
      when 'archives'
        dossiers_count = @archives_count
        @archived_dossiers
      end

      notifications = current_instructeur.notifications_for_groupe_instructeurs(groupe_instructeur_ids)
      @has_en_cours_notifications = notifications[:en_cours].present?
      @has_termine_notifications = notifications[:termines].present?
      @not_archived_notifications_dossier_ids = notifications[:en_cours] + notifications[:termines]

      sorted_ids = procedure_presentation.sorted_ids(@dossiers, dossiers_count, current_instructeur)

      if @current_filters.count > 0
        filtered_ids = procedure_presentation.filtered_ids(@dossiers, statut)
        filtered_sorted_ids = sorted_ids.filter { |id| filtered_ids.include?(id) }
      else
        filtered_sorted_ids = sorted_ids
      end

      page = params[:page].presence || 1

      @filtered_sorted_paginated_ids = Kaminari
        .paginate_array(filtered_sorted_ids)
        .page(page)
        .per(ITEMS_PER_PAGE)

      @projected_dossiers = DossierProjectionService.project(@filtered_sorted_paginated_ids, procedure_presentation.displayed_fields)

      assign_exports
    end

    def deleted_dossiers
      @procedure = procedure
      @deleted_dossiers = @procedure
        .deleted_dossiers
        .order(:dossier_id)
        .page params[:page]
    end

    def update_displayed_fields
      values = params['values'].presence || [].to_json
      procedure_presentation.update_displayed_fields(JSON.parse(values))

      redirect_back(fallback_location: instructeur_procedure_url(procedure))
    end

    def update_sort
      procedure_presentation.update_sort(params[:table], params[:column])

      redirect_back(fallback_location: instructeur_procedure_url(procedure))
    end

    def add_filter
      procedure_presentation.add_filter(statut, params[:field], params[:value])

      redirect_back(fallback_location: instructeur_procedure_url(procedure))
    end

    def remove_filter
      procedure_presentation.remove_filter(statut, params[:field], params[:value])

      redirect_back(fallback_location: instructeur_procedure_url(procedure))
    end

    def download_export
      export_format = params[:export_format]
      time_span_type = params[:time_span_type] || Export.time_span_types.fetch(:everything)
      groupe_instructeurs = current_instructeur
        .groupe_instructeurs
        .where(procedure: procedure)

      @dossier_count = current_instructeur
        .dossiers_count_summary(groupe_instructeur_ids)
        .fetch_values('tous', 'archives')
        .sum

      export = Export.find_or_create_export(export_format, time_span_type, groupe_instructeurs)

      if export.ready? && export.old? && params[:force_export]
        export.destroy
        export = Export.find_or_create_export(export_format, time_span_type, groupe_instructeurs)
      end

      if export.ready?
        respond_to do |format|
          format.js do
            @procedure = procedure
            assign_exports
            flash.notice = "L’export au format \"#{export_format}\" est prêt. Vous pouvez le <a href=\"#{export.file.service_url}\">télécharger</a>"
          end

          format.html do
            redirect_to export.file.service_url
          end
        end
      else
        respond_to do |format|
          notice_message = "Nous générons cet export. Veuillez revenir dans quelques minutes pour le télécharger."

          format.js do
            @procedure = procedure
            assign_exports
            if !params[:no_progress_notification]
              flash.notice = notice_message
            end
          end

          format.html do
            redirect_to instructeur_procedure_url(procedure), notice: notice_message
          end
        end
      end
    end

    def email_notifications
      @procedure = procedure
      @assign_to = assign_to
    end

    def update_email_notifications
      assign_to.update!(assign_to_params)
      flash.notice = 'Vos notifications sont enregistrées.'
      redirect_to instructeur_procedure_path(procedure)
    end

    def stats
      @procedure = procedure
      @usual_traitement_time = @procedure.stats_usual_traitement_time
      @dossiers_funnel = @procedure.stats_dossiers_funnel
      @termines_states = @procedure.stats_termines_states
      @termines_by_week = @procedure.stats_termines_by_week
      @usual_traitement_time_by_month = @procedure.stats_usual_traitement_time_by_month_in_days
    end

    def email_usagers
      @procedure = procedure
      @commentaire = Commentaire.new
      @email_usagers_dossiers = email_usagers_dossiers
      @dossiers_count = @email_usagers_dossiers.count
      @groupe_instructeurs = email_usagers_groupe_instructeurs_label
      @bulk_messages = BulkMessage.includes(:groupe_instructeurs).where(groupe_instructeurs: { id: current_instructeur.groupe_instructeur_ids, procedure: procedure })
    end

    def create_multiple_commentaire
      @procedure = procedure
      errors = []

      email_usagers_dossiers.each do |dossier|
        commentaire = CommentaireService.build(current_instructeur, dossier, commentaire_params)
        if commentaire.save
          commentaire.dossier.update!(last_commentaire_updated_at: Time.zone.now)
        else
          errors << dossier.id
        end
      end

      valid_dossiers_count = email_usagers_dossiers.count - errors.count
      create_bulk_message_mail(valid_dossiers_count, Dossier.states.fetch(:brouillon))

      if errors.empty?
        flash[:notice] = "Tous les messages ont été envoyés avec succès"
      else
        flash[:alert] = "Envoi terminé. Cependant #{errors.count} messages n'ont pas été envoyés"
      end
      redirect_to instructeur_procedure_path(@procedure)
    end

    def create_bulk_message_mail(dossier_count, dossier_state)
      BulkMessage.create(
        dossier_count: dossier_count,
        dossier_state: dossier_state,
        body: commentaire_params[:body],
        sent_at: Time.zone.now,
        instructeur_id: current_instructeur.id,
        piece_jointe: commentaire_params[:piece_jointe],
        groupe_instructeurs: email_usagers_groupe_instructeurs
      )
    end

    private

    def assign_to_params
      params.require(:assign_to)
        .permit(:instant_email_dossier_notifications_enabled, :instant_email_message_notifications_enabled, :daily_email_notifications_enabled, :weekly_email_notifications_enabled)
    end

    def assign_exports
      @exports = Export.find_for_groupe_instructeurs(groupe_instructeur_ids)
    end

    def assign_to
      current_instructeur.assign_to.joins(:groupe_instructeur).find_by(groupe_instructeurs: { procedure: procedure })
    end

    def assign_tos
      @assign_tos ||= current_instructeur
        .assign_to
        .joins(:groupe_instructeur)
        .where(groupe_instructeur: { procedure_id: procedure_id })
    end

    def groupe_instructeur_ids
      @groupe_instructeur_ids ||= assign_tos
        .map(&:groupe_instructeur_id)
    end

    def statut
      @statut ||= (params[:statut].presence || 'a-suivre')
    end

    def procedure_id
      params[:procedure_id]
    end

    def procedure
      Procedure
        .with_attached_logo
        .find(procedure_id)
    end

    def ensure_ownership!
      if !current_instructeur.procedures.include?(procedure)
        flash[:alert] = "Vous n’avez pas accès à cette démarche"
        redirect_to root_path
      end
    end

    def redirect_to_avis_if_needed
      if current_instructeur.procedures.count == 0 && current_instructeur.avis.count > 0
        redirect_to instructeur_all_avis_path
      end
    end

    def procedure_presentation
      @procedure_presentation ||= get_procedure_presentation
    end

    def get_procedure_presentation
      procedure_presentation, errors = current_instructeur.procedure_presentation_and_errors_for_procedure_id(procedure_id)
      if errors.present?
        flash[:alert] = "Votre affichage a dû être réinitialisé en raison du problème suivant : " + errors.full_messages.join(', ')
      end
      procedure_presentation
    end

    def current_filters
      @current_filters ||= procedure_presentation.filters[statut]
    end

    def email_usagers_dossiers
      procedure.dossiers.state_brouillon.where(groupe_instructeur: current_instructeur.groupe_instructeur_ids).includes(:groupe_instructeur)
    end

    def email_usagers_groupe_instructeurs_label
      email_usagers_dossiers.map(&:groupe_instructeur).uniq.map(&:label)
    end

    def email_usagers_groupe_instructeurs
      email_usagers_dossiers.map(&:groupe_instructeur).uniq
    end

    def commentaire_params
      params.require(:commentaire).permit(:body, :piece_jointe)
    end
  end
end
