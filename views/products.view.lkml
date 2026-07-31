view: products {
  sql_table_name: `looker-private-demo.ecomm.products` ;;

  dimension: id {
    primary_key: yes
    type: number
    description: "Unique identifier for the product catalog item."
    sql: ${TABLE}.id ;;
  }

  dimension: name {
    type: string
    description: "Product display name."
    sql: ${TABLE}.name ;;
  }

  dimension: brand {
    type: string
    description: "Product brand or manufacturer name."
    sql: ${TABLE}.brand ;;
  }

  dimension: category {
    type: string
    description: "Merchandise category classification."
    sql: ${TABLE}.category ;;
  }

  dimension: department {
    type: string
    description: "Merchandise department (e.g. Men, Women)."
    sql: ${TABLE}.department ;;
  }

  dimension: cost {
    type: number
    description: "Standard unit cost of the product."
    value_format_name: usd
    sql: ${TABLE}.cost ;;
  }

  dimension: retail_price {
    type: number
    description: "MSRP / list retail price in USD."
    value_format_name: usd
    sql: ${TABLE}.retail_price ;;
  }

  dimension: sku {
    type: string
    description: "Manufacturer SKU identifier."
    sql: ${TABLE}.sku ;;
  }

  dimension: distribution_center_id {
    type: number
    description: "Originating distribution center identifier."
    sql: CAST(${TABLE}.distribution_center_id AS INT64) ;;
  }

  measure: count {
    type: count
    description: "Total distinct products in catalog."
  }

  measure: average_retail_price {
    type: average
    description: "Average retail price across products."
    value_format_name: usd
    sql: ${retail_price} ;;
  }
}
