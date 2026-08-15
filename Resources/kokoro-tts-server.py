#!/usr/bin/env python3
import json
import os
import socket
import sys
import tempfile

import numpy as np
from mlx_audio.tts.utils import load_model
from mlx_audio.audio_io import write as audio_write

SOCKET = os.path.expanduser('~/Library/Application Support/Pi Space/kokoro/tts.sock')
model = load_model('mlx-community/Kokoro-82M-bf16')
os.makedirs(os.path.dirname(SOCKET), exist_ok=True)
try:
    os.unlink(SOCKET)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET)
server.listen(1)

while True:
    conn, _ = server.accept()
    try:
        line = conn.recv(65536).decode().strip()
        request = json.loads(line)
        text = request.get('text', '').strip()
        voice = request.get('voice', 'af_heart')
        speed = float(request.get('speed', 1.0))
        if not text:
            raise ValueError('empty text')
        parts = []
        sample_rate = None
        for result in model.generate(text=text, voice=voice, speed=speed, lang_code='a'):
            parts.append(np.asarray(result.audio))
            sample_rate = result.sample_rate
        if not parts or sample_rate is None:
            raise RuntimeError('Kokoro produced no audio')
        audio = np.concatenate(parts) if len(parts) > 1 else parts[0]
        fd, output = tempfile.mkstemp(prefix='pi-space-kokoro-', suffix='.wav')
        os.close(fd)
        audio_write(output, audio, sample_rate, format='wav')
        response = {'status': 'ok', 'audio_file': output}
    except Exception as error:
        response = {'status': 'error', 'message': str(error)}
    try:
        conn.sendall((json.dumps(response) + '\n').encode())
    finally:
        conn.close()
