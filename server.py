from flask import Flask, request, jsonify, send_file, render_template_string, send_from_directory
from flask_cors import CORS
from werkzeug.utils import secure_filename
import os
import io
import base64
import json
import shutil
from PIL import Image
import numpy as np
from processor import IconProcessor
import traceback

app = Flask(__name__)
CORS(app)

UPLOAD_FOLDER = 'uploads'
EXPORT_FOLDER = 'exports'
STATIC_FOLDER = 'static'
ALLOWED_EXTENSIONS = {'png', 'jpg', 'jpeg'}

for folder in [UPLOAD_FOLDER, EXPORT_FOLDER, STATIC_FOLDER]:
    os.makedirs(folder, exist_ok=True)

app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['EXPORT_FOLDER'] = EXPORT_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024  # 50MB max file size

processor = IconProcessor()

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

@app.route('/')
def index():
    with open(os.path.join(STATIC_FOLDER, 'index.html'), 'r') as f:
        return f.read()

@app.route('/style.css')
def serve_css():
    return send_from_directory(STATIC_FOLDER, 'style.css')

@app.route('/app.js')
def serve_js():
    return send_from_directory(STATIC_FOLDER, 'app.js')

@app.route('/process', methods=['POST'])
def process_image():
    try:
        if 'image' not in request.files:
            return jsonify({'error': 'No image file provided'}), 400

        file = request.files['image']
        if file.filename == '':
            return jsonify({'error': 'No file selected'}), 400

        if not allowed_file(file.filename):
            return jsonify({'error': 'Invalid file type. Only PNG and JPG allowed'}), 400

        # Get parameters from request
        params = {
            'n_layers': int(request.form.get('n_layers', 6)),
            'compactness': float(request.form.get('compactness', 25)),
            'n_segments': int(request.form.get('n_segments', 800)),
            'distance_threshold': request.form.get('distance_threshold', 'auto'),
            'max_regions_per_color': int(request.form.get('max_regions_per_color', 3)),
            'edge_mode': request.form.get('edge_mode', 'soft'),
            'visualize_steps': request.form.get('visualize_steps', 'true') == 'true'
        }

        # Save uploaded file
        filename = secure_filename(file.filename)
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(filepath)

        # Process the image
        result = processor.process_image(filepath, params)

        # Clean up uploaded file
        os.remove(filepath)

        # Convert numpy arrays to base64 for transmission
        if 'layers' in result:
            for i, layer in enumerate(result['layers']):
                img = Image.fromarray((layer * 255).astype(np.uint8), 'RGBA')
                buffer = io.BytesIO()
                img.save(buffer, format='PNG')
                result['layers'][i] = base64.b64encode(buffer.getvalue()).decode('utf-8')

        if 'visualizations' in result:
            for key, viz in result['visualizations'].items():
                if isinstance(viz, np.ndarray):
                    # Handle different array types
                    if viz.dtype == np.bool_ or viz.dtype == bool:
                        viz = (viz * 255).astype(np.uint8)
                    elif viz.dtype == np.float32 or viz.dtype == np.float64:
                        viz = (viz * 255).astype(np.uint8)

                    # Convert to image
                    if len(viz.shape) == 2:
                        img = Image.fromarray(viz, 'L')
                    elif viz.shape[2] == 3:
                        img = Image.fromarray(viz, 'RGB')
                    else:
                        img = Image.fromarray(viz, 'RGBA')

                    buffer = io.BytesIO()
                    img.save(buffer, format='PNG')
                    result['visualizations'][key] = base64.b64encode(buffer.getvalue()).decode('utf-8')

        return jsonify(result)

    except Exception as e:
        print(f"Error processing image: {str(e)}")
        print(traceback.format_exc())
        return jsonify({'error': str(e)}), 500

@app.route('/export', methods=['POST'])
def export_layers():
    try:
        data = request.json
        layers_data = data.get('layers', [])
        export_mode = data.get('mode', 'folder')  # 'folder' or 'suffix'
        base_name = data.get('base_name', 'icon')

        export_id = f"{base_name}_{os.urandom(4).hex()}"

        if export_mode == 'folder':
            export_path = os.path.join(app.config['EXPORT_FOLDER'], export_id)
            os.makedirs(export_path, exist_ok=True)

            # Save each layer
            for i, layer_b64 in enumerate(layers_data):
                layer_data = base64.b64decode(layer_b64)
                img = Image.open(io.BytesIO(layer_data))
                img.save(os.path.join(export_path, f"layer_{i}.png"))

            # Create zip file
            shutil.make_archive(os.path.join(app.config['EXPORT_FOLDER'], export_id),
                               'zip', export_path)

            # Clean up folder
            shutil.rmtree(export_path)

            return send_file(os.path.join(app.config['EXPORT_FOLDER'], f"{export_id}.zip"),
                           as_attachment=True,
                           download_name=f"{base_name}_layers.zip")

        else:  # suffix mode
            # Create temporary folder for individual files
            export_path = os.path.join(app.config['EXPORT_FOLDER'], export_id)
            os.makedirs(export_path, exist_ok=True)

            # Save each layer with suffix
            for i, layer_b64 in enumerate(layers_data):
                layer_data = base64.b64decode(layer_b64)
                img = Image.open(io.BytesIO(layer_data))
                img.save(os.path.join(export_path, f"{base_name}_{i}.png"))

            # Create zip file
            shutil.make_archive(os.path.join(app.config['EXPORT_FOLDER'], export_id),
                               'zip', export_path)

            # Clean up folder
            shutil.rmtree(export_path)

            return send_file(os.path.join(app.config['EXPORT_FOLDER'], f"{export_id}.zip"),
                           as_attachment=True,
                           download_name=f"{base_name}_layers.zip")

    except Exception as e:
        print(f"Error exporting layers: {str(e)}")
        return jsonify({'error': str(e)}), 500

@app.route('/cleanup', methods=['POST'])
def cleanup_exports():
    try:
        # Clean up old export files (older than 1 hour)
        import time
        current_time = time.time()
        for filename in os.listdir(app.config['EXPORT_FOLDER']):
            filepath = os.path.join(app.config['EXPORT_FOLDER'], filename)
            if os.path.getmtime(filepath) < current_time - 3600:  # 1 hour
                os.remove(filepath)
        return jsonify({'status': 'cleaned'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(debug=True, port=5000)