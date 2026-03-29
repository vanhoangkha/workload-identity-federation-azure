"""Query BigQuery from AWS EC2 via Workload Identity Federation."""
import os
from google.cloud import bigquery

def main():
    client = bigquery.Client()
    query = """
    SELECT corpus, COUNT(*) as word_count
    FROM `bigquery-public-data.samples.shakespeare`
    GROUP BY corpus ORDER BY word_count DESC LIMIT 5
    """
    for row in client.query(query).result():
        print(f"  {row.corpus}: {row.word_count}")

if __name__ == "__main__":
    main()
