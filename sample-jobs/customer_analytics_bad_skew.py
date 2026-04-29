"""
BAD PySpark job: Data Skew
===========================

This script creates extreme data skew by assigning 95% of transactions
to a single customer_id, causing one executor to be overwhelmed while
others sit idle. Results in slow stages, potential OOM, or timeouts.
"""

import logging
from datetime import datetime, timedelta
from random import Random

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s - %(message)s")
logger = logging.getLogger("CustomerAnalytics-BAD-SKEW")


def main():
    spark = SparkSession.builder.appName("CustomerAnalytics-BAD-SKEW").getOrCreate()
    logger.info("SparkSession created. Injecting data skew fault.")

    try:
        rng = Random(42)  # nosec B311  # deterministic demo data, not security-sensitive
        categories = ["Electronics", "Clothing", "Food", "Software", "Services"]
        base_ts = datetime(2023, 1, 1)

        # Generate heavily skewed data: 95% of rows go to customer_id=1
        txn_rows = []
        for i in range(1, 100001):
            cid = 1 if rng.random() < 0.95 else rng.randint(2, 500)
            txn_rows.append((i, cid, round(rng.uniform(5.0, 5000.0), 2),
                             rng.choice(categories),
                             base_ts + timedelta(seconds=rng.randint(0, 31536000))))

        transactions = spark.createDataFrame(txn_rows,
            ["transaction_id", "customer_id", "amount", "product_category", "timestamp"])

        logger.info("Generated %d transactions (95%% skewed to customer_id=1)", transactions.count())

        # This groupBy will create massive skew — one partition gets 95K rows
        summary = transactions.groupBy("customer_id").agg(
            F.sum("amount").alias("total_spend"),
            F.count("transaction_id").alias("total_orders"),
            F.collect_list("product_category").alias("all_categories"),  # collect_list on skewed key = memory bomb
        )

        logger.info("Result: %d rows", summary.count())

        # Force a shuffle-heavy operation on the skewed data
        window_result = transactions.repartition(2, "customer_id") \
            .groupBy("customer_id", "product_category") \
            .agg(F.sum("amount").alias("category_spend"))

        logger.info("Window result: %d rows", window_result.count())

    except Exception:
        logger.exception("Job failed with an unhandled exception")
        raise
    finally:
        spark.stop()
        logger.info("SparkSession stopped.")


if __name__ == "__main__":
    main()
