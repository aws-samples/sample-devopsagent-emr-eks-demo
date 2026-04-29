"""
BAD PySpark job: AnalysisException — non-existent column
=========================================================

This script references a column 'transaction_fee' that does not exist
in the dataset, causing a Spark AnalysisException.
"""

import logging
from datetime import datetime, timedelta
from random import Random

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s - %(message)s")
logger = logging.getLogger("CustomerAnalytics-BAD-COLUMN")


def main():
    spark = SparkSession.builder.appName("CustomerAnalytics-BAD-COLUMN").getOrCreate()
    logger.info("SparkSession created. Injecting bad column reference fault.")

    try:
        rng = Random(42)  # nosec B311  # deterministic demo data, not security-sensitive
        categories = ["Electronics", "Clothing", "Food", "Software", "Services"]
        base_ts = datetime(2023, 1, 1)

        txn_rows = [(i, rng.randint(1, 500), round(rng.uniform(5.0, 5000.0), 2),
                      rng.choice(categories),
                      base_ts + timedelta(seconds=rng.randint(0, 31536000)))
                     for i in range(1, 5001)]
        transactions = spark.createDataFrame(txn_rows,
            ["transaction_id", "customer_id", "amount", "product_category", "timestamp"])

        logger.info("Generated %d transactions", transactions.count())

        # BUG: 'transaction_fee' column does not exist in the dataset
        summary = transactions.groupBy("customer_id").agg(
            F.sum("amount").alias("total_spend"),
            F.avg("amount").alias("avg_order_value"),
            F.count("transaction_id").alias("total_orders"),
            F.sum("transaction_fee").alias("total_fees"),  # <-- THIS FAILS
        )

        logger.info("Result: %d rows (should not reach here)", summary.count())

    except Exception:
        logger.exception("Job failed with an unhandled exception")
        raise
    finally:
        spark.stop()
        logger.info("SparkSession stopped.")


if __name__ == "__main__":
    main()
