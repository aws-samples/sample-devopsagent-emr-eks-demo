"""
Sample PySpark job: Customer Analytics
=======================================

Performs customer analytics transformations that exercise common Spark operations:
  - Synthetic data generation (customers + transactions)
  - Aggregations (revenue by segment, transaction count by category)
  - Window functions (running total per customer, rank by spend)
  - Joins (customer enrichment with aggregated transactions)
  - S3 writes for results

This job is designed to produce CloudWatch metrics and Spark History Server data
that the alert reduction system can observe and investigate.

Usage:
  spark-submit customer_analytics.py [--output-path s3://bucket/output/]
"""

import argparse
import logging
import sys
from datetime import datetime, timedelta
from random import Random

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import (
    DateType,
    DoubleType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)
from pyspark.sql.window import Window

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("CustomerAnalytics")


# ---------------------------------------------------------------------------
# Synthetic data generators
# ---------------------------------------------------------------------------
def generate_customers(spark, num_customers=1000):
    """Generate synthetic customer data."""
    logger.info("Generating %d synthetic customers ...", num_customers)

    rng = Random(42)  # nosec B311  # deterministic demo data, not security-sensitive
    segments = ["Enterprise", "SMB", "Startup", "Individual"]
    base_date = datetime(2020, 1, 1)

    rows = []
    for cid in range(1, num_customers + 1):
        rows.append((
            cid,
            f"Customer_{cid}",
            rng.choice(segments),
            (base_date + timedelta(days=rng.randint(0, 1460))).date(),
        ))

    schema = StructType([
        StructField("customer_id", IntegerType(), False),
        StructField("name", StringType(), False),
        StructField("segment", StringType(), False),
        StructField("signup_date", DateType(), False),
    ])

    df = spark.createDataFrame(rows, schema)
    logger.info("Customers generated: %d rows", df.count())
    return df


def generate_transactions(spark, num_customers=1000, num_transactions=50000):
    """Generate synthetic transaction data."""
    logger.info("Generating %d synthetic transactions ...", num_transactions)

    rng = Random(99)  # nosec B311  # deterministic demo data, not security-sensitive
    categories = ["Electronics", "Clothing", "Food", "Software", "Services"]
    base_ts = datetime(2023, 1, 1)

    rows = []
    for tid in range(1, num_transactions + 1):
        rows.append((
            tid,
            rng.randint(1, num_customers),
            round(rng.uniform(5.0, 5000.0), 2),
            rng.choice(categories),
            base_ts + timedelta(seconds=rng.randint(0, 31536000)),
        ))

    schema = StructType([
        StructField("transaction_id", IntegerType(), False),
        StructField("customer_id", IntegerType(), False),
        StructField("amount", DoubleType(), False),
        StructField("product_category", StringType(), False),
        StructField("timestamp", TimestampType(), False),
    ])

    df = spark.createDataFrame(rows, schema)
    logger.info("Transactions generated: %d rows", df.count())
    return df


# ---------------------------------------------------------------------------
# Analytics transformations
# ---------------------------------------------------------------------------
def revenue_by_segment(customers, transactions):
    """Aggregate total revenue by customer segment."""
    logger.info("Computing revenue by segment ...")
    result = (
        transactions
        .join(customers, "customer_id")
        .groupBy("segment")
        .agg(
            F.sum("amount").alias("total_revenue"),
            F.count("transaction_id").alias("transaction_count"),
            F.avg("amount").alias("avg_transaction_value"),
        )
        .orderBy(F.desc("total_revenue"))
    )
    logger.info("Revenue by segment computed.")
    return result


def transaction_count_by_category(transactions):
    """Count transactions per product category."""
    logger.info("Computing transaction count by category ...")
    result = (
        transactions
        .groupBy("product_category")
        .agg(
            F.count("transaction_id").alias("num_transactions"),
            F.sum("amount").alias("total_amount"),
        )
        .orderBy(F.desc("num_transactions"))
    )
    logger.info("Transaction count by category computed.")
    return result


def running_total_per_customer(transactions):
    """Compute running total spend per customer using window functions."""
    logger.info("Computing running total per customer ...")
    window = (
        Window
        .partitionBy("customer_id")
        .orderBy("timestamp")
        .rowsBetween(Window.unboundedPreceding, Window.currentRow)
    )
    result = transactions.withColumn("running_total", F.sum("amount").over(window))
    logger.info("Running totals computed.")
    return result


def rank_customers_by_spend(customers, transactions):
    """Rank customers by total spend using window functions."""
    logger.info("Ranking customers by total spend ...")
    spend = (
        transactions
        .groupBy("customer_id")
        .agg(F.sum("amount").alias("total_spend"))
    )
    window = Window.orderBy(F.desc("total_spend"))
    result = (
        spend
        .join(customers, "customer_id")
        .withColumn("spend_rank", F.rank().over(window))
        .select("spend_rank", "customer_id", "name", "segment", "total_spend")
        .orderBy("spend_rank")
    )
    logger.info("Customer ranking computed.")
    return result


def customer_enrichment(customers, transactions):
    """Join customers with aggregated transaction data."""
    logger.info("Enriching customer data with transaction aggregates ...")
    agg_txn = (
        transactions
        .groupBy("customer_id")
        .agg(
            F.sum("amount").alias("lifetime_value"),
            F.count("transaction_id").alias("total_transactions"),
            F.min("timestamp").alias("first_transaction"),
            F.max("timestamp").alias("last_transaction"),
        )
    )
    result = customers.join(agg_txn, "customer_id", "left")
    logger.info("Customer enrichment complete: %d rows", result.count())
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Customer Analytics PySpark Job")
    parser.add_argument(
        "--output-path",
        default="s3://default-output/customer-analytics/",
        help="S3 path for writing results (default: s3://default-output/customer-analytics/)",
    )
    args, _ = parser.parse_known_args()
    output_path = args.output_path.rstrip("/")

    spark = SparkSession.builder.appName("CustomerAnalytics").getOrCreate()
    logger.info("SparkSession created. App name: CustomerAnalytics")

    try:
        # Generate synthetic data
        customers = generate_customers(spark)
        transactions = generate_transactions(spark)

        # Aggregations
        rev_segment = revenue_by_segment(customers, transactions)
        txn_category = transaction_count_by_category(transactions)

        # Window functions
        running = running_total_per_customer(transactions)
        ranked = rank_customers_by_spend(customers, transactions)

        # Join / enrichment
        enriched = customer_enrichment(customers, transactions)

        # Write results to S3
        logger.info("Writing results to %s ...", output_path)

        rev_segment.write.mode("overwrite").parquet(f"{output_path}/revenue_by_segment")
        logger.info("Wrote revenue_by_segment")

        txn_category.write.mode("overwrite").parquet(f"{output_path}/transaction_count_by_category")
        logger.info("Wrote transaction_count_by_category")

        running.write.mode("overwrite").parquet(f"{output_path}/running_totals")
        logger.info("Wrote running_totals")

        ranked.write.mode("overwrite").parquet(f"{output_path}/customer_rankings")
        logger.info("Wrote customer_rankings")

        enriched.write.mode("overwrite").parquet(f"{output_path}/enriched_customers")
        logger.info("Wrote enriched_customers")

        logger.info("All results written successfully.")

    except Exception:
        logger.exception("Job failed with an unhandled exception")
        raise
    finally:
        spark.stop()
        logger.info("SparkSession stopped.")


if __name__ == "__main__":
    main()
