- dashboard: order_items_overview
  title: "Order Items Overview"
  layout: newspaper
  preferred_viewer: dashboards-next
  description: "CI/CD Demo Dashboard with single tile using order_items.delete_me measure."
  elements:
    - name: total_delete_me_items
      title: "Total Items (Delete Me)"
      model: cicd
      explore: order_items
      type: single_value
      fields: [order_items.delete_me]
      limit: 500
      custom_color_enabled: true
      show_single_value_title: true
      show_comparison: false
      row: 0
      col: 0
      width: 8
      height: 4
