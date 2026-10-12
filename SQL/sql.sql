WITH return_by_order AS (
    SELECT
        order_id,
        COUNT(DISTINCT return_id) AS return_count,
        SUM(qty) AS returned_qty
    FROM Returns
    GROUP BY order_id
),

refund_by_order AS (
    SELECT
        order_id,
        SUM(refund_amount) AS total_refund
    FROM Refunds
    GROUP BY order_id
),

logistics_by_order AS (
    SELECT
        r.order_id,
        SUM(rl.transport_cost) AS logistics_cost
    FROM Returns r
    JOIN Reverse_Logistics rl
        ON r.return_id = rl.return_id
    GROUP BY r.order_id
),

order_economics AS (
    SELECT
        o.order_id,
        COALESCE(p.category, 'Unknown') AS category,
        o.gmv,
        o.discount,
        COALESCE(r.return_count, 0) AS return_count,
        COALESCE(f.total_refund, 0) AS total_refund,
        COALESCE(l.logistics_cost, 0) AS logistics_cost
    FROM Orders o
    LEFT JOIN Products p
        ON o.product_id = p.product_id
    LEFT JOIN Customers c
        ON o.customer_id = c.customer_id
    LEFT JOIN return_by_order r
        ON o.order_id = r.order_id
    LEFT JOIN refund_by_order f
        ON o.order_id = f.order_id
    LEFT JOIN logistics_by_order l
        ON o.order_id = l.order_id
)

SELECT
    category,
    COUNT(DISTINCT order_id) AS total_orders,
    COUNT(DISTINCT CASE
        WHEN return_count > 0 THEN order_id
    END) AS returned_orders,

    ROUND(
        100.0 * COUNT(DISTINCT CASE
            WHEN return_count > 0 THEN order_id
        END) / NULLIF(COUNT(DISTINCT order_id), 0),
        2
    ) AS return_rate_pct,

    ROUND(SUM(total_refund), 2) AS total_refunds,
    ROUND(SUM(logistics_cost), 2) AS reverse_logistics_cost,

    ROUND(SUM(gmv), 2) AS total_gmv,
    ROUND(SUM(discount), 2) AS total_discount,

    ROUND(
        SUM(gmv)
        - SUM(COALESCE(discount, 0))
        - SUM(total_refund)
        - SUM(logistics_cost),
        2
    ) AS estimated_net_contribution

FROM order_economics
GROUP BY category
ORDER BY estimated_net_contribution DESC;

#CTEs for order-level return economics
WITH return_cte AS (
    SELECT
        order_id,
        COUNT(DISTINCT return_id) AS return_count,
        SUM(qty) AS returned_qty
    FROM Returns
    GROUP BY order_id
),
refund_cte AS (
    SELECT
        order_id,
        SUM(refund_amount) AS total_refund
    FROM Refunds
    GROUP BY order_id
),
logistics_cte AS (
    SELECT
        r.order_id,
        SUM(rl.transport_cost) AS logistics_cost
    FROM Returns r
    JOIN Reverse_Logistics rl
        ON r.return_id = rl.return_id
    GROUP BY r.order_id
),
order_economics AS (
    SELECT
        o.order_id,
        o.customer_id,
        COALESCE(p.category, 'Unknown') AS category,
        o.gmv,
        o.discount,
        COALESCE(r.return_count, 0) AS return_count,
        COALESCE(r.returned_qty, 0) AS returned_qty,
        COALESCE(f.total_refund, 0) AS total_refund,
        COALESCE(l.logistics_cost, 0) AS logistics_cost
    FROM Orders o
    LEFT JOIN Products p
        ON o.product_id = p.product_id
    LEFT JOIN return_cte r
        ON o.order_id = r.order_id
    LEFT JOIN refund_cte f
        ON o.order_id = f.order_id
    LEFT JOIN logistics_cte l
        ON o.order_id = l.order_id
)
SELECT
    order_id,
    customer_id,
    category,
    gmv,
    discount,
    return_count,
    returned_qty,
    total_refund,
    logistics_cost,
    gmv
      - COALESCE(discount, 0)
      - total_refund
      - logistics_cost AS estimated_net_contribution
FROM order_economics;

#CTEs for customer-level return economics
WITH return_cte AS (
    SELECT
        order_id,
        COUNT(DISTINCT return_id) AS return_count
    FROM Returns
    GROUP BY order_id
),
refund_cte AS (
    SELECT
        order_id,
        SUM(refund_amount) AS total_refund
    FROM Refunds
    GROUP BY order_id
),
logistics_cte AS (
    SELECT
        r.order_id,
        SUM(rl.transport_cost) AS logistics_cost
    FROM Returns r
    JOIN Reverse_Logistics rl
        ON r.return_id = rl.return_id
    GROUP BY r.order_id
),
order_economics AS (
    SELECT
        o.order_id,
        o.customer_id,
        o.gmv,
        COALESCE(o.discount, 0) AS discount,
        COALESCE(r.return_count, 0) AS return_count,
        COALESCE(f.total_refund, 0) AS total_refund,
        COALESCE(l.logistics_cost, 0) AS logistics_cost
    FROM Orders o
    LEFT JOIN return_cte r
        ON o.order_id = r.order_id
    LEFT JOIN refund_cte f
        ON o.order_id = f.order_id
    LEFT JOIN logistics_cte l
        ON o.order_id = l.order_id
),
customer_economics AS (
    SELECT
        customer_id,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT CASE
            WHEN return_count > 0 THEN order_id
        END) AS returned_orders,
        SUM(gmv) AS total_gmv,
        SUM(discount) AS total_discount,
        SUM(total_refund) AS total_refunds,
        SUM(logistics_cost) AS total_logistics_cost,
        SUM(gmv - discount - total_refund - logistics_cost)
            AS estimated_net_contribution
    FROM order_economics
    GROUP BY customer_id
)
SELECT
    c.customer_id,
    c.segment,
    c.city,
    ce.total_orders,
    ce.returned_orders,
    ROUND(
        100.0 * ce.returned_orders
        / NULLIF(ce.total_orders, 0),
        2
    ) AS return_rate_pct,
    ROUND(ce.total_gmv, 2) AS total_gmv,
    ROUND(ce.total_refunds, 2) AS total_refunds,
    ROUND(ce.total_logistics_cost, 2) AS total_logistics_cost,
    ROUND(ce.estimated_net_contribution, 2)
        AS estimated_net_contribution
FROM customer_economics ce
LEFT JOIN Customers c
    ON ce.customer_id = c.customer_id
ORDER BY estimated_net_contribution ASC;


#Rank categories, sellers, and products by return burden
WITH return_cte AS (
    SELECT
        order_id,
        COUNT(DISTINCT return_id) AS return_count
    FROM Returns
    GROUP BY order_id
),
refund_cte AS (
    SELECT
        order_id,
        SUM(refund_amount) AS refund_amount
    FROM Refunds
    GROUP BY order_id
),
logistics_cte AS (
    SELECT
        r.order_id,
        SUM(rl.transport_cost) AS logistics_cost
    FROM Returns r
    JOIN Reverse_Logistics rl
        ON r.return_id = rl.return_id
    GROUP BY r.order_id
),
order_base AS (
    SELECT
        o.order_id,
        o.product_id,
        COALESCE(p.category, 'Unknown') AS category,
        COALESCE(p.seller_id, 'Unknown') AS seller_id,
        COALESCE(r.return_count, 0) AS return_count,
        COALESCE(f.refund_amount, 0) AS refund_amount,
        COALESCE(l.logistics_cost, 0) AS logistics_cost
    FROM Orders o
    LEFT JOIN Products p
        ON o.product_id = p.product_id
    LEFT JOIN return_cte r
        ON o.order_id = r.order_id
    LEFT JOIN refund_cte f
        ON o.order_id = f.order_id
    LEFT JOIN logistics_cte l
        ON o.order_id = l.order_id
),
category_metrics AS (
    SELECT
        category AS entity_name,
        'Category' AS entity_type,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT CASE
            WHEN return_count > 0 THEN order_id
        END) AS returned_orders,
        SUM(refund_amount) AS total_refunds,
        SUM(logistics_cost) AS total_logistics_cost
    FROM order_base
    GROUP BY category
),
seller_metrics AS (
    SELECT
        seller_id AS entity_name,
        'Seller' AS entity_type,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT CASE
            WHEN return_count > 0 THEN order_id
        END) AS returned_orders,
        SUM(refund_amount) AS total_refunds,
        SUM(logistics_cost) AS total_logistics_cost
    FROM order_base
    GROUP BY seller_id
),
product_metrics AS (
    SELECT
        COALESCE(product_id, 'Unknown') AS entity_name,
        'Product' AS entity_type,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT CASE
            WHEN return_count > 0 THEN order_id
        END) AS returned_orders,
        SUM(refund_amount) AS total_refunds,
        SUM(logistics_cost) AS total_logistics_cost
    FROM order_base
    GROUP BY product_id
),
combined_metrics AS (
    SELECT * FROM category_metrics
    UNION ALL
    SELECT * FROM seller_metrics
    UNION ALL
    SELECT * FROM product_metrics
),
ranked AS (
    SELECT
        entity_type,
        entity_name,
        total_orders,
        returned_orders,
        ROUND(
            100.0 * returned_orders / NULLIF(total_orders, 0),
            2
        ) AS return_rate_pct,
        ROUND(total_refunds, 2) AS total_refunds,
        ROUND(total_logistics_cost, 2) AS total_logistics_cost,
        ROUND(
            total_refunds + total_logistics_cost, 2
        ) AS total_return_burden,
        DENSE_RANK() OVER (
            PARTITION BY entity_type
            ORDER BY
                100.0 * returned_orders / NULLIF(total_orders, 0) DESC
        ) AS return_rate_rank,
        DENSE_RANK() OVER (
            PARTITION BY entity_type
            ORDER BY
                total_refunds + total_logistics_cost DESC
        ) AS cost_burden_rank
    FROM combined_metrics
)
SELECT *
FROM ranked
ORDER BY entity_type, cost_burden_rank, return_rate_rank;


#Detect repeat-return customers.
WITH customer_returns AS (
    SELECT
        o.customer_id,
        COUNT(DISTINCT r.order_id) AS returned_orders,
        COUNT(DISTINCT r.return_id) AS total_returns,
        SUM(r.qty) AS total_returned_qty
    FROM Orders o
    JOIN Returns r
        ON o.order_id = r.order_id
    WHERE o.customer_id IS NOT NULL
    GROUP BY o.customer_id
)
SELECT
    c.customer_id,
    c.segment,
    c.city,
    cr.returned_orders,
    cr.total_returns,
    cr.total_returned_qty
FROM customer_returns cr
LEFT JOIN Customers c
    ON cr.customer_id = c.customer_id
WHERE cr.returned_orders >= 2
ORDER BY cr.returned_orders DESC, cr.total_returns DESC;


# Identify seller/product combinations with unusually high return rates.
WITH product_seller_orders AS (
    SELECT
        p.seller_id,
        o.product_id,
        COUNT(DISTINCT o.order_id) AS total_orders
    FROM Orders o
    JOIN Products p
        ON o.product_id = p.product_id
    WHERE o.order_id IS NOT NULL
      AND o.product_id IS NOT NULL
      AND p.seller_id IS NOT NULL
    GROUP BY p.seller_id, o.product_id
),
returned_combinations AS (
    SELECT
        p.seller_id,
        o.product_id,
        COUNT(DISTINCT r.order_id) AS returned_orders
    FROM Orders o
    JOIN Products p
        ON o.product_id = p.product_id
    JOIN Returns r
        ON o.order_id = r.order_id
    WHERE o.order_id IS NOT NULL
      AND o.product_id IS NOT NULL
      AND p.seller_id IS NOT NULL
    GROUP BY p.seller_id, o.product_id
),
combination_rates AS (
    SELECT
        po.seller_id,
        po.product_id,
        po.total_orders,
        COALESCE(rc.returned_orders, 0) AS returned_orders,
        100.0 * COALESCE(rc.returned_orders, 0)
            / NULLIF(po.total_orders, 0) AS return_rate_pct
    FROM product_seller_orders po
    LEFT JOIN returned_combinations rc
        ON po.seller_id = rc.seller_id
       AND po.product_id = rc.product_id
),
overall_rate AS (
    SELECT
        100.0 * COUNT(DISTINCT r.order_id)
            / NULLIF(COUNT(DISTINCT o.order_id), 0)
            AS overall_return_rate_pct
    FROM Orders o
    LEFT JOIN Returns r
        ON o.order_id = r.order_id
)
SELECT
    cr.seller_id,
    cr.product_id,
    cr.total_orders,
    cr.returned_orders,
    ROUND(cr.return_rate_pct, 2) AS return_rate_pct,
    ROUND(orate.overall_return_rate_pct, 2)
        AS overall_return_rate_pct,
    ROUND(
        cr.return_rate_pct - orate.overall_return_rate_pct, 2
    ) AS percentage_point_difference,
    ROUND(
        cr.return_rate_pct
        / NULLIF(orate.overall_return_rate_pct, 0), 2
    ) AS times_overall_rate
FROM combination_rates cr
CROSS JOIN overall_rate orate
WHERE cr.total_orders >= 20
  AND cr.return_rate_pct > orate.overall_return_rate_pct
ORDER BY cr.return_rate_pct DESC;


# Create return-risk tiers.
WITH customer_orders AS (
    SELECT
        customer_id,
        COUNT(DISTINCT order_id) AS total_orders
    FROM Orders
    WHERE customer_id IS NOT NULL
      AND order_id IS NOT NULL
    GROUP BY customer_id
),
customer_returns AS (
    SELECT
        o.customer_id,
        COUNT(DISTINCT r.order_id) AS returned_orders
    FROM Orders o
    JOIN Returns r
        ON o.order_id = r.order_id
    WHERE o.customer_id IS NOT NULL
    GROUP BY o.customer_id
),
customer_risk AS (
    SELECT
        co.customer_id,
        co.total_orders,
        COALESCE(cr.returned_orders, 0) AS returned_orders,
        100.0 * COALESCE(cr.returned_orders, 0)
            / NULLIF(co.total_orders, 0) AS return_rate_pct
    FROM customer_orders co
    LEFT JOIN customer_returns cr
        ON co.customer_id = cr.customer_id
)
SELECT
    customer_id,
    total_orders,
    returned_orders,
    ROUND(return_rate_pct, 2) AS return_rate_pct,
    CASE
        WHEN total_orders < 3 THEN 'Insufficient Data'
        WHEN return_rate_pct >= 50 THEN 'High Risk'
        WHEN return_rate_pct >= 25 THEN 'Medium Risk'
        ELSE 'Low Risk'
    END AS return_risk_tier
FROM customer_risk
ORDER BY
    CASE
        WHEN total_orders < 3 THEN 4
        WHEN return_rate_pct >= 50 THEN 3
        WHEN return_rate_pct >= 25 THEN 2
        ELSE 1
    END DESC,
    return_rate_pct DESC;