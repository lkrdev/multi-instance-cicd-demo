include: "/views/**/*.view.lkml"

explore: order_items {
  label: "Order Items"
  description: "Core e-commerce explore joining order items with users, inventory items, and products."

  join: users {
    type: left_outer
    relationship: many_to_one
    sql_on: ${order_items.user_id} = ${users.id} ;;
  }

  join: inventory_items {
    type: left_outer
    relationship: many_to_one
    sql_on: ${order_items.inventory_item_id} = ${inventory_items.id} ;;
  }

  join: products {
    type: left_outer
    relationship: many_to_one
    sql_on: ${inventory_items.product_id} = ${products.id} ;;
  }

  join: user_facts {
    type: left_outer
    relationship: many_to_one
    sql_on: ${order_items.user_id} = ${user_facts.user_id} ;;
  }
}
