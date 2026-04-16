class LdapSyncGroupsController < ApplicationController
  layout 'admin'
  before_action :require_admin
  
  def index
    @logs = SyncLog.recent
    @ldap_auths = AuthSourceLdap.all
    @selected_auth_id = LdapSetting.get('ldap_auth_id').to_i
  end
  
  def save
    if params[:settings]
      params[:settings].each do |key, value|
        if value.present?
          LdapSetting.set(key, value)
        else
          LdapSetting.set(key, '')
        end
      end
      
      # Tratează checkbox-urile care nu vin în params când sunt debifate
      unless params[:settings].key?('verbose_logging')
        LdapSetting.set('verbose_logging', 'false')
      end
      
      unless params[:settings].key?('send_report_only_on_changes')
        LdapSetting.set('send_report_only_on_changes', 'false')
      end
      
      flash[:notice] = "Settings saved successfully"
    end
    redirect_to action: :index
  end
  
  def sync
    dry_run = params[:dry_run] == '1'
    
    begin
      require_relative '../../lib/ldap_sync_service'
      service = LdapSyncService.new(dry_run)
      result = service.run
      
      flash[:notice] = "Sync completed: #{result[:users_in_redmine]} users in Redmine, #{result[:groups_processed]} groups, #{result[:users_added]} added, #{result[:users_removed]} removed"
      flash[:warning] = "DRY RUN - No changes made" if dry_run
    rescue => e
      flash[:error] = "Sync failed: #{e.message}"
      logger.error "LDAP Sync Error: #{e.backtrace.join("\n")}"
    end
    
    redirect_to action: :index
  end
  
  def clear_logs
    SyncLog.delete_all
    flash[:notice] = "Logs cleared"
    redirect_to action: :index
  end
end
