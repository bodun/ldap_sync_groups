class CreateSyncLogs < ActiveRecord::Migration[6.1]
  def change
    create_table :sync_logs do |t|
      t.string :level
      t.text :message
      t.timestamps
    end
  end
end
