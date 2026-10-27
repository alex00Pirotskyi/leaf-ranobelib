import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend import app as mod
from backend.engine import InputError, validate_url

VALID = 'https://ranobelib.me/ru/book/202399--test-novel'


@pytest.mark.parametrize('url', [
    'https://evil.com/ru/book/202399--test-novel',
    'http://ranobelib.me/ru/book/202399--test-novel',
    'https://ranobelib.me.evil.com/ru/book/202399--test-novel',
    'https://ranobelib.me/ru/read/202399--test-novel',
    'https://ranobelib.me/ru/book/202399--test-novel/../../etc',
    'https://user:pass@ranobelib.me/ru/book/202399--test-novel',
])
def test_reject_invalid_url(url):
    with pytest.raises(InputError):
        validate_url(url)


def test_accept_valid_url():
    assert validate_url(VALID) == '202399--test-novel'
    assert validate_url(VALID + '?foo=1') == '202399--test-novel'


def test_inspect_validation():
    with TestClient(mod.app) as client:
        response = client.post('/api/book/inspect', json={'url': 'https://example.org'})
    assert response.status_code == 422


def test_export_and_file(monkeypatch, tmp_path):
    monkeypatch.setattr(mod, 'BASE', tmp_path)

    def fake_export(**kwargs):
        kwargs['set_cancel_api'](None)
        kwargs['on_progress'](1, 2, 'Downloading chapters')
        kwargs['on_progress'](2, 2, 'Building EPUB')
        location = Path(kwargs['output_dir'])
        location.mkdir(parents=True, exist_ok=True)
        file = location / 'Sample.epub'
        file.write_bytes(b'EPUB test bytes')
        return file

    monkeypatch.setattr(mod.engine, 'generate_epub', fake_export)
    with TestClient(mod.app) as client:
        created = client.post('/api/jobs', json={'url': VALID})
        assert created.status_code == 202
        job_id = created.json()['id']
        for _ in range(100):
            job = client.get(f'/api/jobs/{job_id}').json()
            if job['status'] != 'queued' and job['status'] != 'running':
                break
            time.sleep(.02)
        assert job['status'] == 'complete', job
        assert job['progress'] == 2
        out = client.get(job['download_url'])
        assert out.status_code == 200
        assert out.content == b'EPUB test bytes'
        assert 'Sample.epub' in out.headers['content-disposition']
