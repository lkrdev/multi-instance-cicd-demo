view: inventory_items {
  sql_table_name: `looker-private-demo.ecomm.inventory_items` ;;

  dimension: id {
    primary_key: yes
    type: number
    description: "Unique identifier for the inventory item."
    sql: ${TABLE}.id ;;
  }

  dimension: product_id {
    type: number
    description: "Foreign key referencing the product."
    sql: ${TABLE}.product_id ;;
  }

  dimension: cost {
    type: number
    description: "Wholesale acquisition cost of the inventory item."
    value_format_name: usd
    sql: ${TABLE}.cost ;;
  }

  dimension: product_category {
    type: string
    description: "Product category classification."
    sql: ${TABLE}.product_category ;;
  }

  dimension: product_name {
    type: string
    description: "Product catalog name."
    sql: ${TABLE}.product_name ;;
  }

  dimension: product_brand {
    type: string
    description: "Product brand name."
    sql: ${TABLE}.product_brand ;;
  }

  dimension: product_department {
    type: string
    description: "Product department (e.g. Men, Women)."
    sql: ${TABLE}.product_department ;;
  }

  dimension: product_sku {
    type: string
    description: "Stock Keeping Unit (SKU) code."
    sql: ${TABLE}.product_sku ;;
  }

  dimension_group: created {
    type: time
    timeframes: [raw, date, week, month, year]
    description: "Date the item was received into inventory."
    sql: ${TABLE}.created_at ;;
  }

  dimension_group: sold {
    type: time
    timeframes: [raw, time, date, week, month, year]
    description: "Timestamp when the inventory item was sold."
    sql: ${TABLE}.sold_at ;;
  }

  dimension: is_sold {
    type: yesno
    description: "Whether the inventory item has been sold."
    sql: ${sold_raw} IS NOT NULL ;;
  }

  measure: count {
    type: count
    description: "Total number of inventory items."
  }

  measure: total_cost {
    type: sum
    description: "Total cost of inventory items."
    value_format_name: usd
    sql: ${cost} ;;
  }

  measure: average_cost {
    type: average
    description: "Average cost per inventory item."
    value_format_name: usd
    sql: ${cost} ;;
  }
}
