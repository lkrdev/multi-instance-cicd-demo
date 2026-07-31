connection: "looker-private-demo"

# Include views and explores
include: "/views/**/*.view.lkml"
include: "/explores/**/*.explore.lkml"
include: "/dashboards/**/*.dashboard.lookml"

# Caching policy datagroup
datagroup: cicd_default_datagroup {
  max_cache_age: "4 hours"
  sql_trigger: SELECT CURRENT_DATE() ;;
}

persist_with: cicd_default_datagroup

# Unit test for LookML CI validation
test: order_items_financial_measures {
  explore_source: order_items {
    column: total_sales {
      field: order_items.total_sale_price
    }
    column: total_margin {
      field: order_items.total_gross_margin
    }
  }
  assert: total_sales_positive {
    expression: ${order_items.total_sales} >= 0 ;;
  }
}

# Unit test verifying the delete_me measure
test: order_items_delete_me_has_rows {
  explore_source: order_items {
    column: delete_me_count {
      field: order_items.delete_me
    }
  }
  assert: delete_me_is_positive {
    expression: ${order_items.delete_me_count} > 0 ;;
  }
}
