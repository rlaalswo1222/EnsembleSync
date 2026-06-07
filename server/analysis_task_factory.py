from abc import ABC, abstractmethod


class AnalysisTaskCreator(ABC):
    @abstractmethod
    def create_task(self, celery_app, cursor, room_id, audio_file_id, job_id):
        pass


class BpmAnalysisTaskCreator(AnalysisTaskCreator):
    def create_task(self, celery_app, cursor, room_id, audio_file_id, job_id):
        return celery_app.send_task(
            "tasks.bpm_analysis",
            args=[job_id, audio_file_id],
            queue="bpm",
        )


class PitchAnalysisTaskCreator(AnalysisTaskCreator):
    def create_task(self, celery_app, cursor, room_id, audio_file_id, job_id):
        return celery_app.send_task(
            "tasks.pitch_analysis",
            args=[job_id, audio_file_id],
            queue="pitch",
        )


class SeparationTaskCreator(AnalysisTaskCreator):
    def create_task(self, celery_app, cursor, room_id, audio_file_id, job_id):
        cursor.execute("SELECT file_type FROM audio_file WHERE id = %s", (audio_file_id,))
        audio_row = cursor.fetchone()
        if not audio_row:
            raise ValueError("audio_file not found")

        file_path = f"uploads/audio/{room_id}/{audio_file_id}.{audio_row['file_type']}"
        return celery_app.send_task(
            "separate_audio_task",
            args=[file_path, room_id, job_id],
            queue="separation",
        )


class AnalysisTaskFactory:
    _creators = {
        "bpm": BpmAnalysisTaskCreator(),
        "pitch": PitchAnalysisTaskCreator(),
        "separation": SeparationTaskCreator(),
    }

    @classmethod
    def supported_types(cls):
        return set(cls._creators.keys())

    @classmethod
    def create_task(cls, job_type, celery_app, cursor, room_id, audio_file_id, job_id):
        return cls._creators[job_type].create_task(
            celery_app,
            cursor,
            room_id,
            audio_file_id,
            job_id,
        )
