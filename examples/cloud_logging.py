"""Send logs to Cloud Logging from AWS EC2 via WIF."""
import socket
import datetime
from google.cloud import logging as cloud_logging

def main(project_id, logger_name="azure-application"):
    client = cloud_logging.Client(project=project_id)
    logger = client.logger(logger_name)
    logger.log_struct({
        "severity": "INFO",
        "message": "Application started",
        "hostname": socket.gethostname(),
        "source": "azure-vm",
        "timestamp": datetime.datetime.now(datetime.UTC).isoformat()
    })
    print(f"Log sent to {logger_name}")

if __name__ == "__main__":
    import sys
    main(sys.argv[1])
