-- ============================================================
-- SQL 能力展示
-- 基于 Olist 电商数据集 + 本地生活业务场景
-- 涵盖：多表 JOIN、窗口函数、RFM 分层、漏斗分析、留存分析
-- ============================================================

-- ============================================================
-- 1. 月度 GMV 趋势（多表 JOIN + 时间聚合）
-- ============================================================
SELECT
    DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m') AS month,
    COUNT(DISTINCT o.order_id) AS order_cnt,
    COUNT(DISTINCT o.customer_id) AS customer_cnt,
    ROUND(SUM(oi.price), 0) AS gmv,
    ROUND(SUM(oi.price) / COUNT(DISTINCT o.order_id), 1) AS avg_order_value
FROM orders o
INNER JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m')
ORDER BY month;

-- ============================================================
-- 2. 品类销售额 TOP10 + 占比（窗口函数）
-- ============================================================
WITH category_gmv AS (
    SELECT
        ct.product_category_name_english AS category,
        ROUND(SUM(oi.price), 0) AS gmv,
        COUNT(DISTINCT o.order_id) AS order_cnt
    FROM orders o
    INNER JOIN order_items oi ON o.order_id = oi.order_id
    INNER JOIN products p ON oi.product_id = p.product_id
    INNER JOIN product_category_name_translation ct
        ON p.product_category_name = ct.product_category_name
    WHERE o.order_status = 'delivered'
    GROUP BY ct.product_category_name_english
)
SELECT
    category,
    gmv,
    order_cnt,
    ROUND(gmv / SUM(gmv) OVER(), 3) AS gmv_share,
    ROUND(SUM(gmv) OVER(ORDER BY gmv DESC) / SUM(gmv) OVER(), 3) AS cumulative_share,
    ROW_NUMBER() OVER(ORDER BY gmv DESC) AS rank
FROM category_gmv
ORDER BY gmv DESC
LIMIT 10;

-- ============================================================
-- 3. 品类月度环比增长率（LAG 窗口函数）
-- ============================================================
WITH monthly_category AS (
    SELECT
        DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m') AS month,
        ct.product_category_name_english AS category,
        ROUND(SUM(oi.price), 0) AS gmv
    FROM orders o
    INNER JOIN order_items oi ON o.order_id = oi.order_id
    INNER JOIN products p ON oi.product_id = p.product_id
    INNER JOIN product_category_name_translation ct
        ON p.product_category_name = ct.product_category_name
    WHERE o.order_status = 'delivered'
    GROUP BY month, ct.product_category_name_english
)
SELECT
    month,
    category,
    gmv,
    LAG(gmv, 1) OVER(PARTITION BY category ORDER BY month) AS prev_month_gmv,
    ROUND((gmv - LAG(gmv, 1) OVER(PARTITION BY category ORDER BY month))
          / NULLIF(LAG(gmv, 1) OVER(PARTITION BY category ORDER BY month), 0), 3) AS mom_growth
FROM monthly_category
WHERE category IN ('health_beauty', 'watches_gifts', 'bed_bath_table', 'sports_leisure', 'computers_accessories')
ORDER BY category, month;

-- ============================================================
-- 4. RFM 用户分层
-- ============================================================
WITH rfm_base AS (
    SELECT
        c.customer_unique_id,
        DATEDIFF('2018-10-01', MAX(o.order_purchase_timestamp)) AS recency,
        COUNT(DISTINCT o.order_id) AS frequency,
        ROUND(SUM(oi.price), 0) AS monetary
    FROM customers c
    INNER JOIN orders o ON c.customer_id = o.customer_id
    INNER JOIN order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
rfm_scored AS (
    SELECT
        customer_unique_id,
        recency,
        frequency,
        monetary,
        NTILE(4) OVER(ORDER BY recency DESC) AS r_score,
        NTILE(4) OVER(ORDER BY frequency ASC) AS f_score,
        NTILE(4) OVER(ORDER BY monetary ASC) AS m_score
    FROM rfm_base
)
SELECT
    CASE
        WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN '高价值客户'
        WHEN r_score >= 3 AND f_score < 3 THEN '新客户 / 发展客户'
        WHEN r_score < 3 AND f_score >= 3 AND m_score >= 3 THEN '流失预警（重要价值）'
        WHEN r_score < 3 AND f_score < 3 THEN '流失客户'
        ELSE '一般客户'
    END AS rfm_segment,
    COUNT(*) AS user_cnt,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct,
    ROUND(AVG(recency), 1) AS avg_recency,
    ROUND(AVG(frequency), 1) AS avg_frequency,
    ROUND(AVG(monetary), 1) AS avg_monetary
FROM rfm_scored
GROUP BY rfm_segment
ORDER BY user_cnt DESC;

-- ============================================================
-- 5. 用户复购率（按首次购买月份做留存分析）
-- ============================================================
WITH first_purchase AS (
    SELECT
        customer_unique_id,
        DATE_FORMAT(MIN(o.order_purchase_timestamp), '%Y-%m') AS cohort_month
    FROM customers c
    INNER JOIN orders o ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY customer_unique_id
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS total_users
    FROM first_purchase
    GROUP BY cohort_month
),
repurchase AS (
    SELECT
        fp.cohort_month,
        DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m') AS purchase_month,
        COUNT(DISTINCT fp.customer_unique_id) AS repurchase_users
    FROM first_purchase fp
    INNER JOIN customers c ON fp.customer_unique_id = c.customer_unique_id
    INNER JOIN orders o ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY fp.cohort_month, DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m')
)
SELECT
    cs.cohort_month,
    cs.total_users,
    rp.purchase_month,
    rp.repurchase_users,
    ROUND(rp.repurchase_users * 100.0 / cs.total_users, 1) AS retention_pct
FROM cohort_size cs
INNER JOIN repurchase rp ON cs.cohort_month = rp.cohort_month
WHERE cs.cohort_month >= '2017-01'
ORDER BY cs.cohort_month, rp.purchase_month;

-- ============================================================
-- 6. 转化漏斗：新用户首单→复购→活跃
-- ============================================================
WITH user_order_seq AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        ROW_NUMBER() OVER(PARTITION BY c.customer_unique_id ORDER BY o.order_purchase_timestamp) AS order_seq
    FROM customers c
    INNER JOIN orders o ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
funnel AS (
    SELECT
        customer_unique_id,
        MAX(CASE WHEN order_seq = 1 THEN 1 ELSE 0 END) AS has_first,
        MAX(CASE WHEN order_seq >= 2 THEN 1 ELSE 0 END) AS has_repurchase,
        MAX(CASE WHEN order_seq >= 3 THEN 1 ELSE 0 END) AS has_third
    FROM user_order_seq
    GROUP BY customer_unique_id
)
SELECT
    '首单' AS step, COUNT(*) AS count FROM funnel WHERE has_first = 1
UNION ALL
SELECT
    '2次+购买', COUNT(*) FROM funnel WHERE has_repurchase = 1
UNION ALL
SELECT
    '3次+购买', COUNT(*) FROM funnel WHERE has_third = 1;

-- ============================================================
-- 7. 商品评分与销量的相关性分析辅助查询
-- ============================================================
SELECT
    p.product_category_name,
    ct.product_category_name_english,
    COUNT(DISTINCT o.order_id) AS order_cnt,
    ROUND(AVG(r.review_score), 2) AS avg_review_score,
    ROUND(SUM(oi.price), 2) AS total_gmv,
    ROUND(AVG(oi.price), 2) AS avg_price
FROM orders o
INNER JOIN order_items oi ON o.order_id = oi.order_id
INNER JOIN products p ON oi.product_id = p.product_id
INNER JOIN product_category_name_translation ct
    ON p.product_category_name = ct.product_category_name
INNER JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
GROUP BY p.product_category_name, ct.product_category_name_english
HAVING COUNT(DISTINCT o.order_id) >= 100
ORDER BY avg_review_score DESC;

-- ============================================================
-- 8. 支付方式分析（PIVOT 思想，用 GROUP BY + CASE WHEN 实现）
-- ============================================================
SELECT
    DATE_FORMAT(o.order_purchase_timestamp, '%Y') AS year,
    p.payment_type,
    COUNT(DISTINCT o.order_id) AS order_cnt,
    ROUND(SUM(p.payment_value), 0) AS total_payment,
    ROUND(AVG(p.payment_installments), 1) AS avg_installments
FROM orders o
INNER JOIN order_payments p ON o.order_id = p.order_id
WHERE o.order_status = 'delivered'
GROUP BY year, p.payment_type
ORDER BY year, total_payment DESC;

-- ============================================================
-- 9. 异常检测辅助查询（IQR 法：识别交易额异常偏高的订单）
-- ============================================================
WITH order_stats AS (
    SELECT
        order_id,
        SUM(price) AS order_amount
    FROM order_items
    GROUP BY order_id
),
quartiles AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY order_amount) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY order_amount) AS q3
    FROM order_stats
)
SELECT
    os.order_id,
    os.order_amount,
    ROUND(q.q3 + 1.5 * (q.q3 - q.q1), 0) AS upper_bound,
    CASE
        WHEN os.order_amount > q.q3 + 1.5 * (q.q3 - q.q1) THEN '异常高'
        ELSE '正常'
    END AS flag
FROM order_stats os, quartiles q
WHERE os.order_amount > q.q3 + 1.5 * (q.q3 - q.q1)
ORDER BY os.order_amount DESC
LIMIT 20;

-- ============================================================
-- 10. 同品类不同商户的对标分析辅助查询
-- ============================================================
WITH merchant_metrics AS (
    SELECT
        s.seller_id,
        ct.product_category_name_english AS category,
        COUNT(DISTINCT o.order_id) AS order_cnt,
        ROUND(SUM(oi.price), 0) AS gmv,
        ROUND(AVG(r.review_score), 2) AS avg_score,
        ROUND(AVG(oi.price), 2) AS avg_price
    FROM sellers s
    INNER JOIN order_items oi ON s.seller_id = oi.seller_id
    INNER JOIN orders o ON oi.order_id = o.order_id
    INNER JOIN products p ON oi.product_id = p.product_id
    INNER JOIN product_category_name_translation ct
        ON p.product_category_name = ct.product_category_name
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY s.seller_id, ct.product_category_name_english
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER(PARTITION BY category ORDER BY gmv DESC) AS rank_by_gmv,
        AVG(gmv) OVER(PARTITION BY category) AS category_avg_gmv,
        AVG(avg_score) OVER(PARTITION BY category) AS category_avg_score
    FROM merchant_metrics
    WHERE order_cnt >= 10
)
SELECT
    category,
    seller_id,
    order_cnt,
    gmv,
    avg_score,
    rank_by_gmv,
    ROUND(gmv / NULLIF(category_avg_gmv, 0), 2) AS gmv_vs_category_avg
FROM ranked
WHERE rank_by_gmv <= 5
ORDER BY category, rank_by_gmv;
