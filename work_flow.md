# set the pytorch environment
/usr/bin/python3.8 -m venv qface_env
source qface_env/bin/activate.csh
python -m pip install --upgrade pip
python -m pip install torch torchvision numpy opencv-python tqdm scikit-learn

# Check if the model works
write the python code in path "scripts/QuantFace/check_mobilefacenet.py"
write the Makefile in the project root for convinently executing the python scripts