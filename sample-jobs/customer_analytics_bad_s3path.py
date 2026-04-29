"""
BAD PySpark job: S3 Path Not Found
====================================

This script references a non-existent S3 path, simulating a job
submission failure due to misconfigured input data path.
"""

import logging

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s - %(message)s")
logger = logging.getLogger("CustomerAnalytics-BAD-S3PATH")


def main():
    spark = SparkSession.builder.appName("CustomerAnalytics-BAD-S3PATH").getOrCreate()
    logger.info("SparkSession created. Injecting bad S3 path fault.")

    try:
        # BUG: This S3 path does not exist
        logger.info("Attempting to read from non-existent S3 path ...")
        df = spark.read.parquet("s3://this-bucket-does-not-exist-12345/input/transactions/")

        logger.info("Read %d rows (should not reach here)", df.count())

    except Exception:
        logger.exception("Job failed with an unhandled exception")
        raise
    finally:
        spark.stop()
        logger.info("SparkSession stopped.")


if __name__ == "__main__":
    main()
