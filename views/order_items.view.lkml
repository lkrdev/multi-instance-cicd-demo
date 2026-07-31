view: order_items {
  sql_table_name: `looker-private-demo.ecomm.order_items` ;;

  dimension: id {
    primary_key: yes
    type: number
    description: "Unique identifier for the order item line."
    sql: ${TABLE}.id ;;
  }

  dimension: order_id {
    type: number
    description: "Foreign key referencing the parent order."
    sql: ${TABLE}.order_id ;;
  }

  dimension: user_id {
    type: number
    description: "Foreign key referencing the purchasing user."
    sql: ${TABLE}.user_id ;;
  }

  dimension: inventory_item_id {
    type: number
    description: "Foreign key referencing the specific inventory unit."
    sql: ${TABLE}.inventory_item_id ;;
  }

  dimension: sale_price {
    type: number
    description: "The actual sale price in USD."
    value_format_name: usd
    sql: ${TABLE}.sale_price ;;
  }

  measure: total_sale_price {
    type: sum
    description: "Total sale price revenue across all order items."
    value_format_name: usd
    sql: ${sale_price} ;;
  }

  dimension: status {
    type: string
    description: "Current order item fulfillment status (e.g. Complete, Shipped, Cancelled, Returned)."
    sql: ${TABLE}.status ;;
  }

  dimension_group: created {
    type: time
    timeframes: [raw, time, date, week, month, quarter, year]
    description: "Timestamp when the order item was placed."
    sql: ${TABLE}.created_at ;;
  }

  dimension_group: shipped {
    type: time
    timeframes: [raw, date, week, month, year]
    description: "Date the order item was shipped."
    sql: ${TABLE}.shipped_at ;;
  }

  dimension_group: delivered {
    type: time
    timeframes: [raw, date, week, month, year]
    description: "Date the order item was delivered."
    sql: ${TABLE}.delivered_at ;;
  }

  dimension_group: returned {
    type: time
    timeframes: [raw, time, date, week, month, year]
    description: "Timestamp when the order item was returned."
    sql: ${TABLE}.returned_at ;;
  }

  # Measures
  measure: count {
    type: count
    description: "Total number of order items."
  }

  measure: delete_me {
    type: count
    description: "Demo count measure intended for CI/CD breaking change validation."
  }

  measure: average_sale_price {
    type: average
    description: "Average sale price per item."
    value_format_name: usd
    sql: ${sale_price} ;;
  }

  measure: total_gross_margin {
    type: sum
    description: "Total gross margin (Sale Price minus Inventory Item Cost)."
    value_format_name: usd
    sql: ${sale_price} - ${inventory_items.cost} ;;
  }

  measure: gross_margin_percentage {
    type: number
    description: "Gross margin percentage (Total Gross Margin / Total Sale Price)."
    value_format_name: percent_2
    sql: 1.0 * ${total_gross_margin} / NULLIF(${total_sale_price}, 0) ;;
  }
}
