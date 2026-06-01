import os
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

load_dotenv()


def get_db():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        database=os.getenv("DB_NAME", "ensemblesync"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD")
    )
