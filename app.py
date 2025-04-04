import os
import zipfile
from flask import Flask, jsonify, request, send_file, render_template
import geopandas as gpd

app = Flask(__name__)

# Path to your shapefile (all related files should be in the same folder)
SHAPEFILE_PATH = 'data/tempMainPipes.shp'

def load_data():
    """Load the shapefile into a GeoDataFrame and transform to EPSG:4326."""
    gdf = gpd.read_file(SHAPEFILE_PATH)
    if gdf.crs != "EPSG:4326":
        gdf = gdf.to_crs(epsg=4326)
    return gdf

def save_data(gdf):
    """Save the GeoDataFrame back to the same shapefile."""
    gdf.to_file(SHAPEFILE_PATH)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/data')
def data():
    """Return shapefile data as GeoJSON."""
    gdf = load_data()
    print("Shapefile loaded")
    geojson = gdf.to_json()
    return geojson

@app.route('/update', methods=['POST'])
def update():
    """
    Update the 'Inst_Year' field for a feature.
    The POST request should contain JSON with keys:
       - id: unique identifier of the feature (Asset_ID)
       - Inst_Year: the new date value.
    """
    data = request.json
    feature_id = data.get('id')
    new_install_year = data.get('Inst_Year')
    if feature_id is None or new_install_year is None:
        return jsonify({'status': 'error', 'message': 'Missing id or Inst_Year'}), 400

    gdf = load_data()
    # Assuming the shapefile has an 'Asset_ID' field as the unique identifier.
    mask = gdf['Asset_ID'] == feature_id
    if not mask.any():
        return jsonify({'status': 'error', 'message': 'Feature not found'}), 404

    gdf.loc[mask, 'Inst_Year'] = new_install_year
    save_data(gdf)  # Save updates to the same file
    return jsonify({'status': 'success'})

@app.route('/download')
def download():
    """
    Package the shapefile files into a zip archive for download.
    """
    folder = os.path.dirname(SHAPEFILE_PATH)
    shapefile_base = os.path.splitext(os.path.basename(SHAPEFILE_PATH))[0]
    files = [f for f in os.listdir(folder) if f.startswith(shapefile_base)]
    zip_filename = f'{shapefile_base}.zip'
    with zipfile.ZipFile(zip_filename, 'w') as zipf:
        for f in files:
            zipf.write(os.path.join(folder, f), arcname=f)
    return send_file(zip_filename, as_attachment=True)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')
