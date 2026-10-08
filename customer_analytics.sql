/*
  Customer Analytics & Revenue Intelligence
  Use this script as a starter for a customer revenue analysis layer.
  Update table names / column names to match your warehouse schema.
*/

-- ============================================================
-- Customer Analytics & Revenue Intelligence
-- SQL Business Analysis
-- ============================================================

-- 1. Overall Sales KPIs
-- Calculates total revenue, unique orders, units sold,
-- and average order value from cleaned positive sales.

SELECT
    ROUND(SUM(Revenue), 2) AS total_revenue,
    COUNT(DISTINCT InvoiceNo) AS total_orders,
    SUM(Quantity) AS total_units_sold,
    ROUND(
        SUM(Revenue) / COUNT(DISTINCT InvoiceNo),
        2
    ) AS average_order_value
FROM sales;

-- 2. Monthly Revenue Performance
-- Tracks revenue, order volume, units sold, and average order value by month.

SELECT
    YearMonth,
    ROUND(SUM(Revenue), 2) AS monthly_revenue,
    COUNT(DISTINCT InvoiceNo) AS total_orders,
    SUM(Quantity) AS units_sold,
    ROUND(
        SUM(Revenue) / COUNT(DISTINCT InvoiceNo),
        2
    ) AS average_order_value
FROM sales
GROUP BY YearMonth
ORDER BY YearMonth;

-- 1) Base customer and revenue model
WITH customer_dim AS (
    SELECT
        c.customer_id,
        c.customer_name,
        c.signup_date,
        c.country,
        c.segment,
        c.is_active,
        DATE_TRUNC('month', c.signup_date)::DATE AS signup_month
    FROM {{ raw_schema }}.customers c
),
order_fact AS (
    SELECT
        o.order_id,
        o.customer_id,
        o.order_date,
        DATE_TRUNC('month', o.order_date)::DATE AS order_month,
        o.order_status,
        o.total_amount,
        o.discount_amount,
        o.net_revenue,
        o.shipping_cost,
        ROW_NUMBER() OVER (PARTITION BY o.customer_id ORDER BY o.order_date) AS customer_order_rank
    FROM {{ raw_schema }}.orders o
    WHERE o.order_status IN ('Completed', 'Paid', 'Shipped')
),
customer_revenue AS (
    SELECT
        c.customer_id,
        c.customer_name,
        c.country,
        c.segment,
        c.signup_date,
        c.signup_month,
        COUNT(DISTINCT o.order_id) AS total_orders,
        SUM(COALESCE(o.net_revenue, 0)) AS lifetime_revenue,
        MIN(o.order_date) AS first_order_date,
        MAX(o.order_date) AS last_order_date,
        AVG(COALESCE(o.net_revenue, 0)) AS avg_order_value,
        DATEDIFF(day, c.signup_date, COALESCE(MAX(o.order_date), c.signup_date)) AS days_since_signup
    FROM customer_dim c
    LEFT JOIN order_fact o
        ON c.customer_id = o.customer_id
    GROUP BY
        c.customer_id,
        c.customer_name,
        c.country,
        c.segment,
        c.signup_date,
        c.signup_month
),
monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', order_date)::DATE AS month_date,
        COUNT(DISTINCT customer_id) AS active_customers,
        COUNT(DISTINCT order_id) AS total_orders,
        SUM(net_revenue) AS monthly_revenue,
        AVG(net_revenue) AS avg_order_value,
        SUM(net_revenue) / NULLIF(COUNT(DISTINCT customer_id), 0) AS revenue_per_customer
    FROM order_fact
    GROUP BY DATE_TRUNC('month', order_date)::DATE
),
customer_lifecycle AS (
    SELECT
        customer_id,
        customer_name,
        segment,
        country,
        signup_date,
        first_order_date,
        last_order_date,
        total_orders,
        lifetime_revenue,
        avg_order_value,
        CASE
            WHEN lifetime_revenue >= 10000 THEN 'High Value'
            WHEN lifetime_revenue >= 5000 THEN 'Mid Value'
            WHEN lifetime_revenue >= 1000 THEN 'Growth'
            ELSE 'New / Low Value'
        END AS revenue_tier,
        CASE
            WHEN total_orders >= 5 THEN 'Loyal'
            WHEN total_orders BETWEEN 2 AND 4 THEN 'Repeat'
            WHEN total_orders = 1 THEN 'Single Purchase'
            ELSE 'No Purchase'
        END AS customer_behavior
    FROM customer_revenue
)
SELECT *
FROM customer_lifecycle
ORDER BY lifetime_revenue DESC;

-- 2) Monthly revenue and engagement trend
SELECT
    month_date,
    active_customers,
    total_orders,
    monthly_revenue,
    avg_order_value,
    revenue_per_customer,
    LAG(monthly_revenue) OVER (ORDER BY month_date) AS prev_month_revenue,
    ROUND((monthly_revenue - LAG(monthly_revenue) OVER (ORDER BY month_date))
          / NULLIF(LAG(monthly_revenue) OVER (ORDER BY month_date), 0) * 100, 2) AS revenue_mom_growth_pct
FROM monthly_revenue
ORDER BY month_date;

-- 3) Customer cohort analysis
WITH customer_orders AS (
    SELECT
        c.customer_id,
        DATE_TRUNC('month', c.signup_date)::DATE AS cohort_month,
        DATE_TRUNC('month', o.order_date)::DATE AS purchase_month,
        DATEDIFF(month, DATE_TRUNC('month', c.signup_date), DATE_TRUNC('month', o.order_date)) AS month_index,
        SUM(COALESCE(o.net_revenue, 0)) AS revenue
    FROM {{ raw_schema }}.customers c
    LEFT JOIN {{ raw_schema }}.orders o
        ON c.customer_id = o.customer_id
    GROUP BY
        c.customer_id,
        DATE_TRUNC('month', c.signup_date)::DATE,
        DATE_TRUNC('month', o.order_date)::DATE
),
cohort_summary AS (
    SELECT
        cohort_month,
        month_index,
        COUNT(DISTINCT customer_id) AS customers_in_cohort,
        SUM(CASE WHEN purchase_month IS NOT NULL THEN 1 ELSE 0 END) AS active_customers,
        SUM(revenue) AS cohort_revenue
    FROM customer_orders
    GROUP BY cohort_month, month_index
)
SELECT
    cohort_month,
    month_index,
    customers_in_cohort,
    active_customers,
    ROUND(active_customers * 100.0 / NULLIF(customers_in_cohort, 0), 2) AS retention_pct,
    cohort_revenue
FROM cohort_summary
ORDER BY cohort_month, month_index;

-- 4) Top customers by revenue and contribution
SELECT
    customer_id,
    customer_name,
    country,
    segment,
    total_orders,
    lifetime_revenue,
    avg_order_value,
    ROUND((lifetime_revenue * 100.0) / SUM(lifetime_revenue) OVER (), 2) AS revenue_share_pct
FROM (
    SELECT
        c.customer_id,
        c.customer_name,
        c.country,
        c.segment,
        COUNT(DISTINCT o.order_id) AS total_orders,
        SUM(COALESCE(o.net_revenue, 0)) AS lifetime_revenue,
        AVG(COALESCE(o.net_revenue, 0)) AS avg_order_value
    FROM {{ raw_schema }}.customers c
    LEFT JOIN {{ raw_schema }}.orders o
        ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.customer_name, c.country, c.segment
) x
ORDER BY lifetime_revenue DESC
LIMIT 20;

-- 5) Product / revenue contribution (if item-level sales exist)
SELECT
    p.product_id,
    p.product_name,
    p.category,
    COUNT(DISTINCT oi.order_id) AS orders_with_product,
    SUM(oi.quantity) AS units_sold,
    SUM(oi.quantity * oi.unit_price) AS gross_product_revenue,
    ROUND((SUM(oi.quantity * oi.unit_price) * 100.0) /
          NULLIF(SUM(SUM(oi.quantity * oi.unit_price)) OVER (), 0), 2) AS product_revenue_share_pct
FROM {{ raw_schema }}.order_items oi
JOIN {{ raw_schema }}.products p
    ON oi.product_id = p.product_id
GROUP BY p.product_id, p.product_name, p.category
ORDER BY gross_product_revenue DESC;

-- 6) Customer segmentation summary
SELECT
    segment,
    COUNT(DISTINCT customer_id) AS total_customers,
    SUM(COALESCE(lifetime_revenue, 0)) AS segment_revenue,
    AVG(COALESCE(lifetime_revenue, 0)) AS avg_customer_revenue,
    SUM(CASE WHEN total_orders >= 2 THEN 1 ELSE 0 END) AS repeat_customers,
    ROUND(SUM(CASE WHEN total_orders >= 2 THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(DISTINCT customer_id), 0), 2) AS repeat_customer_pct
FROM (
    SELECT
        c.customer_id,
        c.segment,
        COUNT(DISTINCT o.order_id) AS total_orders,
        SUM(COALESCE(o.net_revenue, 0)) AS lifetime_revenue
    FROM {{ raw_schema }}.customers c
    LEFT JOIN {{ raw_schema }}.orders o
        ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.segment
) x
GROUP BY segment
ORDER BY segment_revenue DESC;

-- 7) Churn / inactivity monitor
WITH recent_activity AS (
    SELECT
        c.customer_id,
        c.customer_name,
        MAX(o.order_date) AS last_order_date,
        CURRENT_DATE AS report_date,
        DATEDIFF(day, MAX(o.order_date), CURRENT_DATE) AS days_since_last_order
    FROM {{ raw_schema }}.customers c
    LEFT JOIN {{ raw_schema }}.orders o
        ON c.customer_id = o.customer_id
    GROUP BY c.customer_id, c.customer_name
)
SELECT
    customer_id,
    customer_name,
    last_order_date,
    days_since_last_order,
    CASE
        WHEN days_since_last_order IS NULL THEN 'Never Ordered'
        WHEN days_since_last_order <= 30 THEN 'Active'
        WHEN days_since_last_order <= 90 THEN 'At Risk'
        ELSE 'Churned / Dormant'
    END AS customer_status
FROM recent_activity
ORDER BY days_since_last_order DESC;

-- 8) Example materialized view / reporting layer
-- CREATE OR REPLACE VIEW analytics.customer_revenue_summary AS
-- SELECT
--     DATE_TRUNC('month', order_date)::DATE AS month_date,
--     COUNT(DISTINCT customer_id) AS active_customers,
--     SUM(net_revenue) AS revenue,
--     AVG(net_revenue) AS avg_order_value
-- FROM {{ raw_schema }}.orders
-- WHERE order_status IN ('Completed', 'Paid', 'Shipped')
-- GROUP BY DATE_TRUNC('month', order_date)::DATE;

-- Notes:
-- - Replace {{ raw_schema }} with your actual schema (e.g., sales, dbo, public)
-- - If your warehouse uses Snowflake / BigQuery / SQL Server syntax, adjust DATE_TRUNC and DATEDIFF accordingly
-- - Add additional metrics such as CAC, LTV, conversion rate, retention cohort, and NPS as needed


-- ============================================================
-- VERIFIED ANALYSIS USING CLEANED ONLINE RETAIL DATA
-- ============================================================

-- 2. Monthly Revenue Performance
-- Tracks revenue, order volume, units sold, and average order value by month.

SELECT
    YearMonth,
    ROUND(SUM(Revenue), 2) AS monthly_revenue,
    COUNT(DISTINCT InvoiceNo) AS total_orders,
    SUM(Quantity) AS units_sold,
    ROUND(
        SUM(Revenue) / COUNT(DISTINCT InvoiceNo),
        2
    ) AS average_order_value
FROM sales
GROUP BY YearMonth
ORDER BY YearMonth;


-- 3. Month-over-Month Revenue Growth
-- Uses a CTE and LAG window function to compare each month with the previous month.

WITH monthly_revenue AS (
    SELECT
        YearMonth,
        SUM(Revenue) AS revenue
    FROM sales
    GROUP BY YearMonth
),

revenue_growth AS (
    SELECT
        YearMonth,
        revenue,
        LAG(revenue) OVER (
            ORDER BY YearMonth
        ) AS previous_month_revenue
    FROM monthly_revenue
)

SELECT
    YearMonth,
    ROUND(revenue, 2) AS revenue,
    ROUND(previous_month_revenue, 2) AS previous_month_revenue,
    ROUND(
        ((revenue - previous_month_revenue)
        / previous_month_revenue) * 100,
        2
    ) AS mom_growth_percent
FROM revenue_growth
ORDER BY YearMonth;


-- 4. Top 10 Customers by Revenue
-- Identifies the highest-value known customers based on total revenue.

SELECT
    CAST(CustomerID AS INTEGER) AS customer_id,
    ROUND(SUM(Revenue), 2) AS total_revenue,
    COUNT(DISTINCT InvoiceNo) AS total_orders,
    SUM(Quantity) AS units_purchased,
    ROUND(
        SUM(Revenue) / COUNT(DISTINCT InvoiceNo),
        2
    ) AS average_order_value
FROM sales
WHERE CustomerID IS NOT NULL
GROUP BY CustomerID
ORDER BY total_revenue DESC
LIMIT 10;
-- 5. Top 10 Merchandise Products by Revenue
-- Excludes administrative/service entries from product analysis.

SELECT
    Description AS product,
    ROUND(SUM(Revenue), 2) AS product_revenue,
    SUM(Quantity) AS units_sold,
    COUNT(DISTINCT InvoiceNo) AS total_orders
FROM sales
WHERE Description NOT IN (
    'AMAZON FEE',
    'Manual',
    'POSTAGE',
    'CRUK Commission',
    'Bank Charges',
    'DOTCOM POSTAGE',
    'Discount'
)
GROUP BY Description
ORDER BY product_revenue DESC
LIMIT 10;


-- 6. Country Revenue Performance
-- Compares revenue, orders, units sold, and average order value across markets.

SELECT
    Country,
    ROUND(SUM(Revenue), 2) AS total_revenue,
    COUNT(DISTINCT InvoiceNo) AS total_orders,
    SUM(Quantity) AS units_sold,
    ROUND(
        SUM(Revenue) / COUNT(DISTINCT InvoiceNo),
        2
    ) AS average_order_value
FROM sales
GROUP BY Country
ORDER BY total_revenue DESC;


-- 7. Top 10 Customer Revenue Concentration
-- Measures how much customer-attributed revenue is generated
-- by the ten highest-revenue customers.

WITH customer_revenue AS (
    SELECT
        CustomerID,
        SUM(Revenue) AS revenue
    FROM sales
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID
),

ranked_customers AS (
    SELECT
        CustomerID,
        revenue,
        ROW_NUMBER() OVER (
            ORDER BY revenue DESC
        ) AS revenue_rank
    FROM customer_revenue
)

SELECT
    ROUND(
        SUM(
            CASE
                WHEN revenue_rank <= 10 THEN revenue
                ELSE 0
            END
        ),
        2
    ) AS top_10_customer_revenue,

    ROUND(SUM(revenue), 2) AS total_customer_revenue,

    ROUND(
        SUM(
            CASE
                WHEN revenue_rank <= 10 THEN revenue
                ELSE 0
            END
        ) / SUM(revenue) * 100,
        2
    ) AS top_10_revenue_share_percent

FROM ranked_customers;
-- 8. Customer Segment Performance
-- Compares customer count, behavior, revenue, and revenue contribution
-- across RFM customer segments.

SELECT
    Segment,
    COUNT(*) AS customer_count,
    ROUND(AVG(Recency), 2) AS avg_recency_days,
    ROUND(AVG(Frequency), 2) AS avg_order_frequency,
    ROUND(AVG(Monetary), 2) AS avg_customer_revenue,
    ROUND(SUM(Monetary), 2) AS total_segment_revenue,
    ROUND(
        SUM(Monetary) /
        (SELECT SUM(Monetary) FROM customer_rfm) * 100,
        2
    ) AS revenue_share_percent
FROM customer_rfm
GROUP BY Segment
ORDER BY total_segment_revenue DESC;


-- 9. High-Value Customer Concentration
-- Measures how much customer-attributed revenue is generated
-- by Champions and Loyal Customers.

SELECT
    SUM(
        CASE
            WHEN Segment IN ('Champions', 'Loyal Customers')
            THEN 1
            ELSE 0
        END
    ) AS high_value_customers,

    COUNT(*) AS total_customers,

    ROUND(
        SUM(
            CASE
                WHEN Segment IN ('Champions', 'Loyal Customers')
                THEN 1
                ELSE 0
            END
        ) * 100.0 / COUNT(*),
        2
    ) AS customer_share_percent,

    ROUND(
        SUM(
            CASE
                WHEN Segment IN ('Champions', 'Loyal Customers')
                THEN Monetary
                ELSE 0
            END
        ),
        2
    ) AS high_value_revenue,

    ROUND(
        SUM(
            CASE
                WHEN Segment IN ('Champions', 'Loyal Customers')
                THEN Monetary
                ELSE 0
            END
        ) / SUM(Monetary) * 100,
        2
    ) AS revenue_share_percent

FROM customer_rfm;

-- 10. Cancellation Performance
-- Measures cancellation activity and compares cancellation value
-- with positive sales value.

SELECT
    COUNT(*) AS cancellation_rows,
    COUNT(DISTINCT InvoiceNo) AS cancellation_invoices,
    ROUND(SUM(Cancellation_Value), 2) AS cancellation_value,

    ROUND(
        SUM(Cancellation_Value) /
        (
            (SELECT SUM(Revenue) FROM sales)
            + SUM(Cancellation_Value)
        ) * 100,
        2
    ) AS cancellation_value_rate_percent,

    ROUND(
        (SELECT SUM(Revenue) FROM sales)
        - SUM(Cancellation_Value),
        2
    ) AS cancellation_adjusted_revenue

FROM cancellations;

-- 11. Monthly Cancellation Analysis
-- Tracks cancellation value and cancellation invoice volume over time.

SELECT
    substr(InvoiceDate, 1, 7) AS YearMonth,
    ROUND(SUM(Cancellation_Value), 2) AS cancellation_value,
    COUNT(DISTINCT InvoiceNo) AS cancellation_invoices
FROM cancellations
GROUP BY substr(InvoiceDate, 1, 7)
ORDER BY YearMonth;

-- 12. December 2011 Cancellation Outlier Analysis
-- Identifies the transactions driving the unusually high
-- December cancellation value.

SELECT
    Description,
    ROUND(SUM(Cancellation_Value), 2) AS cancellation_value,
    ABS(SUM(Quantity)) AS cancelled_units,
    COUNT(DISTINCT InvoiceNo) AS cancellation_invoices
FROM cancellations
WHERE substr(InvoiceDate, 1, 7) = '2011-12'
GROUP BY Description
ORDER BY cancellation_value DESC
LIMIT 10;

-- 13. December Cancellation Outlier Contribution
-- Measures how much of December 2011 cancellation value
-- was driven by PAPER CRAFT , LITTLE BIRDIE.

SELECT
    ROUND(SUM(Cancellation_Value), 2) AS december_cancellation_value,

    ROUND(
        SUM(
            CASE
                WHEN Description = 'PAPER CRAFT , LITTLE BIRDIE'
                THEN Cancellation_Value
                ELSE 0
            END
        ),
        2
    ) AS paper_craft_cancellation_value,

    ROUND(
        SUM(
            CASE
                WHEN Description = 'PAPER CRAFT , LITTLE BIRDIE'
                THEN Cancellation_Value
                ELSE 0
            END
        ) / SUM(Cancellation_Value) * 100,
        2
    ) AS paper_craft_share_percent,

    ROUND(
        SUM(
            CASE
                WHEN Description <> 'PAPER CRAFT , LITTLE BIRDIE'
                THEN Cancellation_Value
                ELSE 0
            END
        ),
        2
    ) AS december_value_without_outlier

FROM cancellations
WHERE substr(InvoiceDate, 1, 7) = '2011-12';

-- ============================================================
-- 14. KEY BUSINESS INSIGHTS
-- ============================================================
-- 1. Clean positive sales generated approximately $10.64M
--    across 19,960 orders, with an average order value of $533.17.
--
-- 2. Revenue accelerated strongly in Sep-Nov 2011.
--    November was the highest full month at approximately $1.50M.
--    December 2011 is a partial month and should not be directly
--    compared with complete months.
--
-- 3. The United Kingdom generated approximately 84.59% of total
--    positive sales revenue, showing substantial geographic
--    concentration.
--
-- 4. 4,338 identified customers generated approximately
--    $8.89M, representing 83.51% of positive sales revenue.
--
-- 5. Champions and Loyal Customers represent only 34.16% of
--    identified customers but generate 73.92% of
--    customer-attributed revenue.
--
-- 6. The top 10 customers generate 17.30% of
--    customer-attributed revenue.
--
-- 7. Cancellation value totaled approximately $896.81K.
--    The cancellation-value ratio is 7.77%.
--    This metric should not be interpreted as a true product
--    return rate.
--
-- 8. December 2011 showed $205.12K in cancellation value.
--    PAPER CRAFT , LITTLE BIRDIE alone contributed $168.47K,
--    or 82.13%, indicating a transaction-level outlier rather
--    than a broad cancellation increase.
--
-- 9. Cancellation-adjusted revenue is approximately $9.75M.
--    This is an analytical estimate, not audited net revenue.