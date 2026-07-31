view: users {
  sql_table_name: `looker-private-demo.ecomm.users` ;;

  dimension: id {
    primary_key: yes
    type: number
    description: "Unique identifier for the user."
    sql: ${TABLE}.id ;;
  }

  dimension: first_name {
    type: string
    description: "User first name."
    sql: ${TABLE}.first_name ;;
  }

  dimension: last_name {
    type: string
    description: "User last name."
    sql: ${TABLE}.last_name ;;
  }

  dimension: name {
    type: string
    description: "Full concatenated user name."
    sql: CONCAT(${first_name}, ' ', ${last_name}) ;;
  }

  dimension: email {
    type: string
    description: "User contact email address."
    sql: ${TABLE}.email ;;
  }

  dimension: age {
    type: number
    description: "User age in years."
    sql: ${TABLE}.age ;;
  }

  dimension: gender {
    type: string
    description: "User gender."
    sql: ${TABLE}.gender ;;
  }

  dimension: city {
    type: string
    description: "City of user residence."
    sql: ${TABLE}.city ;;
  }

  dimension: state {
    type: string
    description: "US state or territory of user residence."
    sql: ${TABLE}.state ;;
  }

  dimension: country {
    type: string
    description: "Country of user residence."
    sql: ${TABLE}.country ;;
  }

  dimension: zip {
    type: zipcode
    description: "Postal code of user residence."
    sql: ${TABLE}.zip ;;
  }

  dimension: traffic_source {
    type: string
    description: "Acquisition channel that brought the user to the site."
    sql: ${TABLE}.traffic_source ;;
  }

  dimension_group: created {
    type: time
    timeframes: [raw, time, date, week, month, year]
    description: "Timestamp when the user account was registered."
    sql: ${TABLE}.created_at ;;
  }

  measure: count {
    type: count
    description: "Total number of users."
  }
}
