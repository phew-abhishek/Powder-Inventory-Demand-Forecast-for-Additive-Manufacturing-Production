

-- POWDER INVENTORY & DEMAND FORECAST - SQL QUERIES
-->> For AM Production Scheduling and Inventory Optimization
-- =============================================================================

-- 1. HISTORICAL DEMAND AGGREGATION QUERIES

-- Monthly demand aggregation by powder type
SELECT 
    powder_type,
    DATE_FORMAT(order_date, '%Y-%m') as order_month,
    YEAR(order_date) as order_year,
    MONTH(order_date) as order_month_num,
    COUNT(*) as order_count,
    SUM(quantity_kg) as total_demand_kg,
    AVG(quantity_kg) as avg_order_size_kg,
    SUM(total_cost_usd) as total_value_usd,
    AVG(unit_cost_usd) as avg_unit_cost_usd,
    STDDEV(quantity_kg) as demand_std_dev
FROM am_orders_historical
WHERE order_date >= DATE_SUB(NOW(), INTERVAL 18 MONTH)
GROUP BY powder_type, DATE_FORMAT(order_date, '%Y-%m'), YEAR(order_date), MONTH(order_date)
ORDER BY powder_type, order_year, order_month_num;

-- Weekly demand aggregation for short-term forecasting
SELECT 
    powder_type,
    YEARWEEK(order_date, 1) as year_week,
    DATE(DATE_SUB(order_date, INTERVAL WEEKDAY(order_date) DAY)) as week_start_date,
    COUNT(*) as order_count,
    SUM(quantity_kg) as weekly_demand_kg,
    AVG(quantity_kg) as avg_order_size_kg
FROM am_orders_historical
WHERE order_date >= DATE_SUB(NOW(), INTERVAL 12 MONTH)
GROUP BY powder_type, YEARWEEK(order_date, 1), DATE(DATE_SUB(order_date, INTERVAL WEEKDAY(order_date) DAY))
ORDER BY powder_type, year_week;

-- Seasonality analysis by powder type
WITH monthly_avg AS (
    SELECT 
        powder_type,
        MONTH(order_date) as month_num,
        AVG(quantity_kg) as avg_monthly_demand
    FROM am_orders_historical
    WHERE order_date >= DATE_SUB(NOW(), INTERVAL 24 MONTH)
    GROUP BY powder_type, MONTH(order_date)
),
overall_avg AS (
    SELECT 
        powder_type,
        AVG(quantity_kg) as overall_avg_demand
    FROM am_orders_historical
    WHERE order_date >= DATE_SUB(NOW(), INTERVAL 24 MONTH)
    GROUP BY powder_type
)
SELECT 
    ma.powder_type,
    ma.month_num,
    MONTHNAME(STR_TO_DATE(ma.month_num, '%m')) as month_name,
    ma.avg_monthly_demand,
    oa.overall_avg_demand,
    ROUND(ma.avg_monthly_demand / oa.overall_avg_demand, 3) as seasonality_index
FROM monthly_avg ma
JOIN overall_avg oa ON ma.powder_type = oa.powder_type
ORDER BY ma.powder_type, ma.month_num;

-- 2. DEMAND FORECASTING DATA PREPARATION
-- =============================================================================

-- Rolling 3-month demand trends
SELECT 
    powder_type,
    order_month,
    total_demand_kg,
    LAG(total_demand_kg, 1) OVER (PARTITION BY powder_type ORDER BY order_month) as prev_month_demand,
    LAG(total_demand_kg, 2) OVER (PARTITION BY powder_type ORDER BY order_month) as prev_2_month_demand,
    LAG(total_demand_kg, 3) OVER (PARTITION BY powder_type ORDER BY order_month) as prev_3_month_demand,
    AVG(total_demand_kg) OVER (
        PARTITION BY powder_type 
        ORDER BY order_month 
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) as rolling_3month_avg,
    AVG(total_demand_kg) OVER (
        PARTITION BY powder_type 
        ORDER BY order_month 
        ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
    ) as rolling_6month_avg
FROM (
    SELECT 
        powder_type,
        DATE_FORMAT(order_date, '%Y-%m') as order_month,
        SUM(quantity_kg) as total_demand_kg
    FROM am_orders_historical
    GROUP BY powder_type, DATE_FORMAT(order_date, '%Y-%m')
) monthly_data
ORDER BY powder_type, order_month;

-- Priority and industry impact analysis
SELECT 
    powder_type,
    DATE_FORMAT(order_date, '%Y-%m') as order_month,
    priority,
    industry_sector,
    COUNT(*) as order_count,
    SUM(quantity_kg) as demand_kg,
    AVG(quantity_kg) as avg_order_kg,
    SUM(total_cost_usd) as total_value
FROM am_orders_historical
WHERE order_date >= DATE_SUB(NOW(), INTERVAL 12 MONTH)
GROUP BY powder_type, DATE_FORMAT(order_date, '%Y-%m'), priority, industry_sector
ORDER BY powder_type, order_month, priority, industry_sector;

-- 3. INVENTORY MANAGEMENT QUERIES
-- =============================================================================

-- Current inventory status (assuming we have an inventory table)
/*
CREATE TABLE powder_inventory (
    powder_type VARCHAR(100) PRIMARY KEY,
    current_stock_kg DECIMAL(10,2),
    reorder_point_kg DECIMAL(10,2),
    max_stock_level_kg DECIMAL(10,2),
    safety_stock_kg DECIMAL(10,2),
    shelf_life_days INT,
    storage_cost_per_kg_per_day DECIMAL(8,4),
    ordering_cost_per_order DECIMAL(10,2),
    lead_time_days INT,
    supplier_name VARCHAR(100),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
*/

-- Inventory status with reorder alerts
SELECT 
    pi.powder_type,
    pi.current_stock_kg,
    pi.reorder_point_kg,
    pi.safety_stock_kg,
    pi.max_stock_level_kg,
    pi.lead_time_days,
    pi.shelf_life_days,
    CASE 
        WHEN pi.current_stock_kg <= pi.reorder_point_kg THEN 'REORDER_REQUIRED'
        WHEN pi.current_stock_kg <= pi.safety_stock_kg THEN 'CRITICAL_LOW'
        WHEN pi.current_stock_kg >= pi.max_stock_level_kg THEN 'OVERSTOCK'
        ELSE 'NORMAL'
    END as stock_status,
    pi.current_stock_kg - pi.reorder_point_kg as stock_buffer_kg,
    ROUND(pi.current_stock_kg / NULLIF(recent_demand.avg_weekly_demand, 0), 1) as weeks_of_supply
FROM powder_inventory_master as pi
LEFT JOIN (
    SELECT 
        powder_type,
        AVG(weekly_demand_kg) as avg_weekly_demand
    FROM (
        SELECT 
            powder_type,
            YEARWEEK(order_date, 1) as year_week,
            SUM(quantity_kg) as weekly_demand_kg
        FROM am_orders_historical
        WHERE order_date >= DATE_SUB(NOW(), INTERVAL 12 WEEK)
        GROUP BY powder_type, YEARWEEK(order_date, 1)
    ) weekly_data
    GROUP BY powder_type
) recent_demand ON pi.powder_type = recent_demand.powder_type;

-- 4. LOT TRACKING AND SHELF LIFE MANAGEMENT
-- =============================================================================

/*
CREATE TABLE powder_lots_tracking (
    lot_id VARCHAR(50) PRIMARY KEY,
    powder_type VARCHAR(100),
    quantity_kg DECIMAL(10,2),
    received_date DATE,
    expiry_date DATE,
    supplier_name VARCHAR(100),
    unit_cost_usd DECIMAL(8,2),
    storage_location VARCHAR(50),
    status ENUM('AVAILABLE', 'ALLOCATED', 'EXPIRED', 'CONSUMED') DEFAULT 'AVAILABLE',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (powder_type) REFERENCES powder_inventory(powder_type)
);
*/

-- Expiring inventory alert (FEFO - First Expired, First Out)
SELECT 
    lot_id,
    powder_type,
    quantity_kg,
    expiry_date,
    DATEDIFF(expiry_date, CURDATE()) as days_to_expiry,
    supplier_name,
    storage_location,
    quantity_kg * unit_cost_usd as lot_value_usd,
    CASE 
        WHEN DATEDIFF(expiry_date, CURDATE()) <= 0 THEN 'EXPIRED'
        WHEN DATEDIFF(expiry_date, CURDATE()) <= 30 THEN 'CRITICAL_EXPIRY'
        WHEN DATEDIFF(expiry_date, CURDATE()) <= 60 THEN 'WARNING_EXPIRY'
        ELSE 'GOOD'
    END as expiry_status
FROM powder_lots_tracking 
WHERE status = 'AVAILABLE'
ORDER BY powder_type, expiry_date;

-- Lot allocation for production orders (FEFO strategy)
SELECT 
    pl.lot_id,
    pl.powder_type,
    pl.quantity_kg as available_qty,
    pl.expiry_date,
    DATEDIFF(pl.expiry_date, CURDATE()) as days_to_expiry,
    ROW_NUMBER() OVER (PARTITION BY pl.powder_type ORDER BY pl.expiry_date) as allocation_priority
FROM powder_lots_tracking as pl
WHERE pl.status = 'AVAILABLE' 
    AND pl.expiry_date > CURDATE()
    AND pl.powder_type = 'Titanium Ti-6Al-4V'  -- Example for specific powder
ORDER BY pl.powder_type, pl.expiry_date;

-- 5. EOQ CALCULATION SUPPORT QUERIES
-- =============================================================================

-- Annual demand calculation for EOQ
SELECT 
    powder_type,
    SUM(quantity_kg) as annual_demand_kg,
    COUNT(*) as annual_order_count,
    AVG(quantity_kg) as avg_order_size_kg,
    STDDEV(quantity_kg) as demand_std_dev,
    AVG(unit_cost_usd) as avg_unit_cost,
    SUM(total_cost_usd) as total_annual_value
FROM am_orders_historical
WHERE order_date >= DATE_SUB(NOW(), INTERVAL 12 MONTH)
GROUP BY powder_type
ORDER BY annual_demand_kg DESC;

-- Lead time analysis
SELECT 
    powder_type,
    supplier_name,
    AVG(lead_time_days) as avg_lead_time_days,
    MIN(lead_time_days) as min_lead_time_days,
    MAX(lead_time_days) as max_lead_time_days,
    STDDEV(lead_time_days) as lead_time_std_dev
FROM powder_inventory_master as pi
GROUP BY powder_type, supplier_name;

-- 6. PRODUCTION SCHEDULE INTEGRATION
-- =============================================================================

-- Future production schedule demand (assumes production_schedule table exists)
/*
CREATE TABLE production_schedule (
    schedule_id INT PRIMARY KEY AUTO_INCREMENT,
    powder_type VARCHAR(100),
    scheduled_date DATE,
    required_quantity_kg DECIMAL(10,2),
    priority ENUM('High', 'Medium', 'Low'),
    industry_sector VARCHAR(50),
    job_number VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
*/

-- Production schedule vs inventory availability
SELECT 
    ps.scheduled_date,
    ps.powder_type,
    ps.required_quantity_kg,
    pi.current_stock_kg,
    SUM(ps.required_quantity_kg) OVER (
        PARTITION BY ps.powder_type 
        ORDER BY ps.scheduled_date 
        ROWS UNBOUNDED PRECEDING
    ) as cumulative_demand_kg,
    pi.current_stock_kg - SUM(ps.required_quantity_kg) OVER (
        PARTITION BY ps.powder_type 
        ORDER BY ps.scheduled_date 
        ROWS UNBOUNDED PRECEDING
    ) as projected_stock_kg,
    CASE 
        WHEN pi.current_stock_kg - SUM(ps.required_quantity_kg) OVER (
            PARTITION BY ps.powder_type 
            ORDER BY ps.scheduled_date 
            ROWS UNBOUNDED PRECEDING
        ) < pi.safety_stock_kg THEN 'SHORTAGE_RISK'
        ELSE 'ADEQUATE'
    END as stock_adequacy
FROM future_production_schedule as ps
JOIN powder_inventory pi ON ps.powder_type = pi.powder_type
WHERE ps.scheduled_date <= DATE_ADD(CURDATE(), INTERVAL 90 DAY)
ORDER BY ps.powder_type, ps.scheduled_date;

-- 7. KPI CALCULATION QUERIES
-- =============================================================================

-- Stockout prevention KPI
SELECT 
    powder_type,
    COUNT(*) as total_scheduled_jobs,
    SUM(CASE WHEN stock_adequacy = 'SHORTAGE_RISK' THEN 1 ELSE 0 END) as at_risk_jobs,
    ROUND(
        (1 - SUM(CASE WHEN stock_adequacy = 'SHORTAGE_RISK' THEN 1 ELSE 0 END) / COUNT(*)) * 100, 
        2
    ) as stockout_prevention_rate_percent
FROM (
    -- Previous query results would be used here
    SELECT 'Titanium Ti-6Al-4V' as powder_type, 'ADEQUATE' as stock_adequacy
    UNION ALL SELECT 'Titanium Ti-6Al-4V', 'ADEQUATE'
    UNION ALL SELECT 'Titanium Ti-6Al-4V', 'SHORTAGE_RISK'
) stockout_analysis
GROUP BY powder_type;

-- Expired powder reduction KPI
SELECT 
    powder_type,
    COUNT(*) as total_lots,
    SUM(CASE WHEN status = 'EXPIRED' THEN quantity_kg ELSE 0 END) as expired_qty_kg,
    SUM(quantity_kg) as total_qty_kg,
    ROUND(
        SUM(CASE WHEN status = 'EXPIRED' THEN quantity_kg ELSE 0 END) / 
        NULLIF(SUM(quantity_kg), 0) * 100, 
        2
    ) as expiry_rate_percent,
    SUM(CASE WHEN status = 'EXPIRED' THEN quantity_kg * unit_cost_usd ELSE 0 END) as expired_value_usd
FROM powder_lots_tracking
WHERE received_date >= DATE_SUB(CURDATE(), INTERVAL 12 MONTH)
GROUP BY powder_type;

-- Inventory turnover ratio
SELECT 
    demand.powder_type,
    demand.annual_demand_kg,
    inventory.avg_stock_kg,
    ROUND(demand.annual_demand_kg / NULLIF(inventory.avg_stock_kg, 0), 2) as inventory_turnover_ratio,
    ROUND(365 / NULLIF(demand.annual_demand_kg / NULLIF(inventory.avg_stock_kg, 0), 0), 1) as days_sales_outstanding
FROM (
    SELECT 
        powder_type,
        SUM(quantity_kg) as annual_demand_kg
    FROM am_orders_historical
    WHERE order_date >= DATE_SUB(NOW(), INTERVAL 12 MONTH)
    GROUP BY powder_type
) demand
JOIN (
    SELECT 
        powder_type,
        AVG(current_stock_kg) as avg_stock_kg
    FROM powder_inventory
    GROUP BY powder_type
) inventory ON demand.powder_type = inventory.powder_type;

