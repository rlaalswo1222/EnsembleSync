import psycopg2
import psycopg2.extras


def get_db():
    return psycopg2.connect(
        host="localhost",
        database="ensemblesync",
        user="rlaalswo1222",
        password="edu2438!"
    )
