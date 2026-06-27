class CreateGenericResources < ActiveRecord::Migration[7.0]
  def change
    create_table :generic_resources do |t|
      t.string :name
      t.string :message

      t.timestamps
    end
  end
end
