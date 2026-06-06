
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
--用于经营大盘监控、产品&定价优化等

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
--根据二八法则，识别出核心爆款、潜力品类、长尾滞销，有助于业务端资源聚焦、SKU精简、备货规划

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
--聚焦重点品类环比分析，快速定位增长/下滑原因，识别潜力爆款/区分是需求下滑、缺货断货、竞品冲击还是运营下架；

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
--基于rfm模型对用户分层， 协助精细化用户运营、分配营销资源、诊断业务问题

-- ============================================================
-- 5. 用户复购率（按首次购买月份做留存分析）
-- ============================================================
WITH first_purchase AS (
    SELECT
        customer_unique_id,
        DATE_FORMAT(MIN(o.order_purchase_timestamp), '%Y-%m') AS cohort_month --取首次下单时间，作为该用户同期群月份
    FROM customers c
    INNER JOIN orders o ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY customer_unique_id
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS total_users  -- 每个首次下单月的用户总数（同期群初始规模）
    FROM first_purchase
    GROUP BY cohort_month
),
repurchase AS (
    SELECT
        fp.cohort_month,
        DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m') AS purchase_month,  -- 用户本次下单的月份（可能是首次月，也可能是复购月）
        COUNT(DISTINCT fp.customer_unique_id) AS repurchase_users   -- 该同期群在这个purchase_month有下单行为的去重用户数
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
    ROUND(rp.repurchase_users * 100.0 / cs.total_users, 1) AS retention_pct   -- 留存率=消费月复购人数 / 同期群总用户数（保留1位小数）
FROM cohort_size cs
INNER JOIN repurchase rp ON cs.cohort_month = rp.cohort_month
WHERE cs.cohort_month >= '2017-01' AND rp.purchase_month > cs.cohort_month  -- 只看消费月晚于首次下单月的留存
ORDER BY cs.cohort_month, rp.purchase_month;
-- 用于衡量用户留存质量，以指导运营策略，进行营收预测、活动效果评估等行为


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
    '首单' AS step, COUNT(*) AS count FROM funnel WHERE has_first = 1  --把 3 个独立的统计结果合并成 1 张表，新增计算字段为购买频次类型
UNION ALL
SELECT
    '2次+购买', COUNT(*) FROM funnel WHERE has_repurchase = 1
UNION ALL
SELECT
    '3次+购买', COUNT(*) FROM funnel WHERE has_third = 1; 
--通过转化漏斗、纵/横向对比，评估复购健康度、定位复购流失环节，结合品类/客单价分析，指导运营策略

-- ============================================================
-- 7. 商品评分与销量的相关性分析辅助查询
-- ============================================================
SELECT
    p.product_category_name,
    ct.product_category_name_english,
    COUNT(DISTINCT o.order_id) AS order_cnt, -- 该品类有效订单数
    ROUND(AVG(r.review_score), 2) AS avg_review_score,  -- 该品类用户平均评分
    ROUND(SUM(oi.price), 2) AS total_gmv,
    ROUND(AVG(oi.price), 2) AS avg_product_price, --单品均价
    ROUND(SUM(oi.price) / COUNT(DISTINCT o.order_id), 2) AS avg_order_value --品类客单价（订单维度）
FROM orders o
INNER JOIN order_items oi ON o.order_id = oi.order_id
INNER JOIN products p ON oi.product_id = p.product_id
INNER JOIN product_category_name_translation ct
    ON p.product_category_name = ct.product_category_name
INNER JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
GROUP BY p.product_category_name, ct.product_category_name_english
HAVING COUNT(DISTINCT o.order_id) >= 100  -- 过滤条件：仅保留订单量≥100的主流品类，剔除长尾小众品类
ORDER BY avg_review_score DESC, total_gmv DESC;
-- 根据销量、用户评分筛选出优质品类，指导品类定价策略（客单价、单品均价→满减、配件销售）、运营资源分配策略，同时也可通过竞品对标找到“差异化优势品类”、为品类拓展分析高评分小众品类

-- ============================================================
-- 8. 支付方式分析（PIVOT 思想，用 GROUP BY + CASE WHEN 实现）
-- ============================================================
WITH year_total AS (
    SELECT
        DATE_FORMAT(o.order_purchase_timestamp, '%Y') AS year,
        ROUND(SUM(p.payment_value), 0) AS year_total_payment
    FROM orders o
    INNER JOIN order_payments p ON o.order_id = p.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY year
)
SELECT
    t.year,
    t.payment_type,
    t.order_cnt,
    t.total_payment,
    ROUND(t.total_payment * 100.0 / yt.year_total_payment, 1) AS payment_pct,
    t.avg_installments,
    t.avg_order_value
FROM (
    SELECT
        DATE_FORMAT(o.order_purchase_timestamp, '%Y') AS year,
        p.payment_type,
        COUNT(DISTINCT o.order_id) AS order_cnt,
        ROUND(SUM(p.payment_value), 0) AS total_payment,
        ROUND(AVG(p.payment_installments), 1) AS avg_installments,
        ROUND(SUM(p.payment_value) / COUNT(DISTINCT o.order_id), 0) AS avg_order_value
    FROM orders o
    INNER JOIN order_payments p ON o.order_id = p.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY year, p.payment_type
) t
INNER JOIN year_total yt ON t.year = yt.year
ORDER BY t.year, t.total_payment DESC;
--根据支付方式拆解，优化分期策略，如免息分期刺激高客单价消费；基于消费能力分层，定向推送高端商品；

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
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY order_amount) AS q1, -- Q1：下四分位数
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY order_amount) AS q3 -- Q3：上四分位数
    FROM order_stats
) --一行数据，(q1,q2)
SELECT
    os.order_id,
    os.order_amount,
    ROUND(q.q3 + 1.5 * (q.q3 - q.q1), 0) AS upper_bound,
    CASE
        WHEN os.order_amount > q.q3 + 1.5 * (q.q3 - q.q1) THEN '异常高'
        WHEN os.order_amount < q.q1 - 1.5 * (q.q3 - q.q1) THEN '异常低'
        ELSE '正常'
    END AS flag
FROM order_stats os, quartiles q -- 笛卡尔积：把四分位数结果关联到所有订单
WHERE os.order_amount > q.q3 + 1.5 * (q.q3 - q.q1)
   or os.order_amount < q.q3 - 1.5 * (q.q3 - q.q1)
ORDER BY FIELD(flag, '异常高', '异常低'),-- 优先按异常类型排序
         os.order_amount DESC
LIMIT 50;
-- 基于IQR异常检测，排查异常交易，如刷单、商品价格设置错误、恶意套现、0元刷单、优惠券滥用等；在后续分析中进行数据清洗，剔除相关异常订单；

-- ============================================================
-- 10. 同品类不同商户的对标分析辅助查询
-- ============================================================
WITH merchant_metrics AS (
    SELECT
        s.seller_id,
        ct.product_category_name_english AS category,
        COUNT(DISTINCT o.order_id) AS order_cnt,
        ROUND(SUM(oi.price), 0) AS gmv,
        -- 填充NULL评分：无评价则用0（也可改用品类均值，需后续关联）
        ROUND(AVG(COALESCE(r.review_score, 0)), 2) AS avg_score,
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
        AVG(avg_score) OVER(PARTITION BY category) AS category_avg_score,
        SUM(order_cnt) OVER(PARTITION BY category) AS category_total_orders  -- 品类总订单量
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
    ROUND(gmv / NULLIF(category_avg_gmv, 0), 2) AS gmv_vs_category_avg,
    ROUND(avg_score - category_avg_score, 2) AS score_vs_category_avg,
    ROUND(order_cnt * 100.0 / NULLIF(category_total_orders, 0), 1) AS order_pct_in_category
FROM ranked
WHERE rank_by_gmv <= 5
ORDER BY category, rank_by_gmv;
-- 对标分析，挖掘头部商家与标杆，如高gmv+高评分，分析其运营策略并推广；高GMV+低评分，重点关注售后、质量问题；低GMV+高评分，针对性扶持流量、运营策略等；
-- 分析品类竞争格局，如果品类集中度高，引入新商家；如果品类内商家业绩差距小，可推出激励活动激发竞争；
-- 优化招商&商家分层运营，top商家提供专属权益，绑定核心；高评分商家纳入潜力池，定向招商扶持；低GMV品类，分析原因，扩充品类商家or调整品类策略
-- 定价策略参考，对比top商家的品类单价和品类均价，如果top商家均价高且GMV仍高，则用户认可高价高质，引导同品类商家优化商品品质、推广策略；

