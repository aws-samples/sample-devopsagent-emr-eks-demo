"""
BAD PySpark job: OOM Failure via crossJoin
==========================================

This script intentionally introduces a crossJoin bug that creates a
cartesian product, causing data explosion and OOM/timeout failure.

The bug: uses crossJoin instead of a proper join on customer_id,
multiplying every row by every other row.
"""

import logging
from datetime import datetime, timedelta
from random import Random

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import (
    DateType, DoubleType, IntegerType, StringType,
    StructField, StructType, TimestampType,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s - %(message)s")
logger = logging.getLogger("CustomerAnalytics-BAD-OOM")


def main():
    spark = SparkSession.builder.appName("CustomerAnalytics-BAD-OOM").getOrCreate()
    logger.info("SparkSession created. Injecting OOM fault via crossJoin.")

    try:
        rng = Random(42)  # nosec B311  # deterministic demo data, not security-sensitive
        segments = ["Enterprise", "SMB", "Startup", "Individual"]
        categories = ["Electronics", "Clothing", "Food", "Software", "Services"]
        base_date = datetime(2020, 1, 1)
        base_ts = datetime(2023, 1, 1)

        # Generate customers
        cust_rows = [(i, f"Customer_{i}", rng.choice(segments),
                      (base_date + timedelta(days=rng.randint(0, 1460))).date())
                     for i in range(1, 5001)]
        customers = spark.createDataFrame(cust_rows, ["customer_id", "name", "segment", "signup_date"])

        # Generate transactions
        txn_rows = [(i, rng.randint(1, 5000), round(rng.uniform(5.0, 5000.0), 2),
                      rng.choice(categories),
                      base_ts + timedelta(seconds=rng.randint(0, 31536000)))
                     for i in range(1, 100001)]
        transactions = spark.createDataFrame(txn_rows,
            ["transaction_id", "customer_id", "amount", "product_category", "timestamp"])

        logger.info("Data generated: %d customers, %d transactions", customers.count(), transactions.count())

        # NEW FEATURE: Product category analysis
        product_analysis = transactions.select("customer_id", "product_category", "amount")
        customer_base = transactions.select("customer_id", "timestamp").distinct()

        # BUG: crossJoin instead of .join(customer_base, "customer_id")
        # This creates a cartesian product — every row x every row = data explosion
        logger.info("Performing crossJoin (THIS WILL CAUSE OOM) ...")
        customer_base_renamed = customer_base.withColumnRenamed("customer_id", "cust_id")
        enriched_data = product_analysis.crossJoin(customer_base_renamed)

        # This will blow up
        customer_metrics = enriched_data.groupBy("customer_id").agg(
            F.sum("amount").alias("total_spend"),
            F.count("*").alias("total_records"),
        )

        # BUG: collect() pulls entire crossJoin result to driver, causing OOM
        all_data = enriched_data.collect()  # This will OOM the driver
        result_count = len(all_data)
        logger.info("Result count: %d (should not reach here)", result_count)

    except Exception:
        logger.exception("Job failed with an unhandled exception")
        raise
    finally:
        spark.stop()
        logger.info("SparkSession stopped.")


if __name__ == "__main__":
    main()
