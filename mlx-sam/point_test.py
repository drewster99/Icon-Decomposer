import requests
from PIL import Image
from mlxformers import MlxSamModel
from transformers import SamProcessor
from transformers.tokenization_utils import BatchEncoding # Temporary

model = MlxSamModel.from_pretrained("EduardoPacheco/mlx-sam-vit-base")
processor = SamProcessor.from_pretrained("EduardoPacheco/mlx-sam-vit-base")

img_url = "https://huggingface.co/ybelkada/segment-anything/resolve/main/assets/car.png"
raw_image = Image.open(requests.get(img_url, stream=True).raw).convert("RGB")
input_points = [[[450, 600]]] # 2D localization of a window

inputs = processor(raw_image, input_points=input_points, return_tensors="np")
# There's currently a bug when using `return_tensors="np"`
inputs["input_points"] = inputs["input_points"][None]
inputs = BatchEncoding(data=dict(inputs), tensor_type="mlx")

outputs = model(**inputs)
masks = model.post_process_masks(
  masks=outputs.pred_masks,
  original_sizes=inputs.original_sizes,
  reshaped_input_sizes=inputs.reshaped_input_sizes,
  pad_size=processor.image_processor.pad_size,
  binarize=False,
)
scores = outputs.iou_scores