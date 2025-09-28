from flask import Flask, request, jsonify, send_file, render_template_string, send_from_directory
from flask_cors import CORS
from werkzeug.utils import secure_filename
import os
import io
import base64
import json
import shutil
import hashlib
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
    import time
    start_time = time.time()
    with open(os.path.join(STATIC_FOLDER, 'index.html'), 'r') as f:
        content = f.read()
    print(f"[GET /] Time: {(time.time() - start_time)*1000:.2f}ms")
    return content

@app.route('/style.css')
def serve_css():
    import time
    start_time = time.time()
    response = send_from_directory(STATIC_FOLDER, 'style.css')
    print(f"[GET /style.css] Time: {(time.time() - start_time)*1000:.2f}ms")
    return response

@app.route('/app.js')
def serve_js():
    import time
    start_time = time.time()
    response = send_from_directory(STATIC_FOLDER, 'app.js')
    print(f"[GET /app.js] Time: {(time.time() - start_time)*1000:.2f}ms")
    return response

@app.route('/layer-grouping.js')
def serve_layer_grouping():
    import time
    start_time = time.time()
    response = send_from_directory(STATIC_FOLDER, 'layer-grouping.js')
    print(f"[GET /layer-grouping.js] Time: {(time.time() - start_time)*1000:.2f}ms")
    return response

@app.route('/process', methods=['POST'])
def process_image():
    import time
    start_time = time.time()

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
            'max_regions_per_color': int(request.form.get('max_regions_per_color', 2)),
            'edge_mode': request.form.get('edge_mode', 'soft'),
            'visualize_steps': request.form.get('visualize_steps', 'true') == 'true'
        }

        # Read file content to generate hash
        file_content = file.read()
        file.seek(0)  # Reset file pointer for saving

        # Generate content hash for cache key
        content_hash = hashlib.sha256(file_content).hexdigest()[:16]

        # Save uploaded file with UUID to prevent conflicts
        original_filename = secure_filename(file.filename)
        file_ext = os.path.splitext(original_filename)[1]
        unique_filename = f"{os.urandom(8).hex()}{file_ext}"
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)

        print("\n" + "=" * 60)
        print("IMAGE PROCESSING REQUEST")
        print("=" * 60)
        print(f"Original filename: {file.filename}")
        print(f"Saved as: {unique_filename}")
        print(f"Content hash: {content_hash}")
        print(f"File size: {len(file_content):,} bytes")
        print("\nParameters:")
        for key, value in params.items():
            print(f"  {key}: {value}")
        print("-" * 60)

        save_time = time.time()
        file.save(filepath)
        print(f"File save time: {(time.time() - save_time):.3f}s")

        # Process the image - pass content hash as cache key
        process_start = time.time()
        params['cache_key'] = content_hash  # Use content hash as cache key
        result = processor.process_image(filepath, params)
        print(f"Total processing time: {(time.time() - process_start):.3f}s")

        # Clean up uploaded file
        os.remove(filepath)

        # Convert numpy arrays to base64 for transmission
        encoding_start = time.time()
        if 'layers' in result:
            layers_preview = []
            layers_full = []

            for i, layer in enumerate(result['layers']):
                # Convert to image
                img = Image.fromarray((layer * 255).astype(np.uint8), 'RGBA')

                # Full resolution for exports
                buffer = io.BytesIO()
                img.save(buffer, format='PNG')
                layers_full.append(base64.b64encode(buffer.getvalue()).decode('utf-8'))

                # 256px preview for display
                img_preview = img.resize((256, 256), Image.Resampling.LANCZOS)
                buffer = io.BytesIO()
                img_preview.save(buffer, format='PNG')
                layers_preview.append(base64.b64encode(buffer.getvalue()).decode('utf-8'))

            result['layers'] = layers_preview
            result['layers_full'] = layers_full

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

                    # Visualizations are already 256px from processor
                    buffer = io.BytesIO()
                    img.save(buffer, format='PNG')
                    result['visualizations'][key] = base64.b64encode(buffer.getvalue()).decode('utf-8')

        print(f"Response encoding: {(time.time() - encoding_start):.3f}s")
        print(f"TOTAL REQUEST TIME: {(time.time() - start_time):.3f}s")
        print("=" * 60 + "\n")

        return jsonify(result)

    except Exception as e:
        print(f"Error processing image: {str(e)}")
        print(traceback.format_exc())
        return jsonify({'error': str(e)}), 500

@app.route('/export', methods=['POST'])
def export_layers():
    import time
    start_time = time.time()

    try:
        data = request.json
        layers_data = data.get('layers', [])
        export_mode = data.get('mode', 'folder')  # 'folder' or 'suffix'
        base_name = data.get('base_name', 'icon')

        print(f"\n[POST /export] Starting export")
        print(f"  Mode: {export_mode}")
        print(f"  Base name: {base_name}")
        print(f"  Number of layers: {len(layers_data)}")

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

            print(f"[POST /export] Export completed in {(time.time() - start_time)*1000:.2f}ms")
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

            print(f"[POST /export] Export completed in {(time.time() - start_time)*1000:.2f}ms")
            return send_file(os.path.join(app.config['EXPORT_FOLDER'], f"{export_id}.zip"),
                           as_attachment=True,
                           download_name=f"{base_name}_layers.zip")

    except Exception as e:
        print(f"[POST /export] Error after {(time.time() - start_time)*1000:.2f}ms: {str(e)}")
        return jsonify({'error': str(e)}), 500

@app.route('/reconstruct', methods=['POST'])
def reconstruct_layers():
    """Generate reconstruction from selected layers"""
    import time
    start_time = time.time()

    try:
        data = request.json
        layers_data = data.get('layers', [])
        selected_indices = data.get('selected', [])

        print(f"\n[POST /reconstruct] Starting reconstruction")
        print(f"  Total layers: {len(layers_data)}")
        print(f"  Selected layers: {selected_indices}")

        if not layers_data or not selected_indices:
            return jsonify({'reconstruction': None})

        # Decode layers
        layers = []
        layer_size = None
        for idx in selected_indices:
            if idx < len(layers_data):
                layer_b64 = layers_data[idx]
                layer_data = base64.b64decode(layer_b64)
                img = Image.open(io.BytesIO(layer_data))
                layer_array = np.array(img)
                layers.append(layer_array)

                # Get the size from the first layer
                if layer_size is None:
                    layer_size = layer_array.shape[:2]

        # Create reconstruction with the same size as the input layers
        if layer_size is None:
            return jsonify({'reconstruction': None})

        reconstruction = np.zeros((layer_size[0], layer_size[1], 4), dtype=np.float32)
        for layer in layers:
            # Convert to float if needed
            if layer.dtype == np.uint8:
                layer = layer.astype(np.float32) / 255.0

            # Add layer to reconstruction
            alpha = layer[:, :, 3:4]
            reconstruction[:, :, :3] += layer[:, :, :3] * alpha
            # Update alpha channel
            reconstruction[:, :, 3] = np.maximum(reconstruction[:, :, 3], layer[:, :, 3])

        # Clip and convert to uint8
        reconstruction = np.clip(reconstruction * 255, 0, 255).astype(np.uint8)

        # Convert to image
        img = Image.fromarray(reconstruction, 'RGBA')

        # Convert to base64
        buffer = io.BytesIO()
        img.save(buffer, format='PNG')
        reconstruction_b64 = base64.b64encode(buffer.getvalue()).decode('utf-8')

        print(f"[POST /reconstruct] Reconstruction completed in {(time.time() - start_time)*1000:.2f}ms")
        return jsonify({'reconstruction': reconstruction_b64})

    except Exception as e:
        print(f"[POST /reconstruct] Error after {(time.time() - start_time)*1000:.2f}ms: {str(e)}")
        return jsonify({'error': str(e)}), 500

@app.route('/export-icon-bundle', methods=['POST'])
def export_icon_bundle():
    """Export layers as an Apple Icon Composer bundle (.icon)"""
    import time
    start_time = time.time()

    try:
        data = request.json
        layers_data = data.get('layers', [])
        base_name = data.get('base_name', 'icon')
        layer_stats = data.get('layer_stats', [])  # Contains pixel counts for ordering

        print(f"\n[POST /export-icon-bundle] Starting Apple icon bundle export")
        print(f"  Base name: {base_name}")
        print(f"  Number of layers: {len(layers_data)}")

        if not layers_data:
            return jsonify({'error': 'No layers to export'}), 400

        # Create temporary bundle directory
        export_id = f"{base_name}_{os.urandom(4).hex()}"
        bundle_name = f"{base_name}.icon"
        bundle_path = os.path.join(app.config['EXPORT_FOLDER'], export_id, bundle_name)
        assets_path = os.path.join(bundle_path, 'Assets')
        os.makedirs(assets_path, exist_ok=True)

        # Sort layers by pixel count (largest first for bottom-to-top ordering)
        layer_info = []
        for i, layer_b64 in enumerate(layers_data):
            pixel_count = layer_stats[i] if i < len(layer_stats) else 1000000 - i
            layer_info.append((i, layer_b64, pixel_count))
        layer_info.sort(key=lambda x: x[2], reverse=True)

        # Save layer images and prepare groups
        groups = []
        for idx, (original_idx, layer_b64, pixel_count) in enumerate(layer_info):
            # Save PNG file
            layer_data = base64.b64decode(layer_b64)
            img = Image.open(io.BytesIO(layer_data))
            image_filename = f"layer_{idx}.png"
            img.save(os.path.join(assets_path, image_filename))

            # Create group for this layer
            is_bottom_layer = (idx == 0)  # First in list = largest = bottom layer

            group = {
                "hidden": False,
                "layers": [
                    {
                        "image-name": image_filename,
                        "name": f"layer_{idx}",
                        "fill": "automatic",
                        "hidden": False
                    }
                ],
                "shadow": {
                    "kind": "layer-color",
                    "opacity": 0.5
                },
                "translucency": {
                    "enabled": True,
                    "value": 0.4
                },
                "lighting": "individual" if is_bottom_layer else "combined",
                "specular": True
            }

            # Add glass effect only to bottom layer
            if is_bottom_layer:
                group["layers"][0]["glass"] = True

            groups.append(group)

        # Create icon.json
        icon_json = {
            "fill": "automatic",
            "groups": groups,
            "supported-platforms": {
                "circles": ["watchOS"],
                "squares": "shared"
            }
        }

        # Write icon.json with proper formatting
        icon_json_path = os.path.join(bundle_path, 'icon.json')
        with open(icon_json_path, 'w') as f:
            json.dump(icon_json, f, indent=2)

        # Create ZIP file containing the .icon bundle
        zip_path = os.path.join(app.config['EXPORT_FOLDER'], f"{export_id}")
        shutil.make_archive(zip_path, 'zip',
                          os.path.join(app.config['EXPORT_FOLDER'], export_id))

        # Clean up temporary directory
        shutil.rmtree(os.path.join(app.config['EXPORT_FOLDER'], export_id))

        print(f"[POST /export-icon-bundle] Bundle export completed in {(time.time() - start_time)*1000:.2f}ms")
        return send_file(f"{zip_path}.zip",
                        as_attachment=True,
                        download_name=f"{base_name}.icon.zip")

    except Exception as e:
        print(f"[POST /export-icon-bundle] Error after {(time.time() - start_time)*1000:.2f}ms: {str(e)}")
        import traceback
        print(traceback.format_exc())
        return jsonify({'error': str(e)}), 500

@app.route('/cleanup', methods=['POST'])
def cleanup_exports():
    import time
    start_time = time.time()

    try:
        # Clean up old export files (older than 1 hour)
        current_time = time.time()
        files_removed = 0
        for filename in os.listdir(app.config['EXPORT_FOLDER']):
            filepath = os.path.join(app.config['EXPORT_FOLDER'], filename)
            if os.path.getmtime(filepath) < current_time - 3600:  # 1 hour
                os.remove(filepath)
                files_removed += 1

        print(f"[POST /cleanup] Removed {files_removed} old files in {(time.time() - start_time)*1000:.2f}ms")
        return jsonify({'status': 'cleaned', 'files_removed': files_removed})
    except Exception as e:
        print(f"[POST /cleanup] Error after {(time.time() - start_time)*1000:.2f}ms: {str(e)}")
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    app.run(debug=True, port=port)