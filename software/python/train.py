import torch
import torch.nn as nn
import torch.optim as optim
from model import MobileFacenet

def train():
    # 1. Initialize Network
    if torch.cuda.is_available():
        device = torch.device("cuda")
    elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
    net = MobileFacenet().to(device)

    # 2. Setup Optimizer and Loss
    # Note: If you need training for ArcFace margin loss, you will need to add ArcMarginProduct layer
    # For basic ASIC/hardware synthesis, standard CE or MSE with distillation may apply.
    criterion = nn.CrossEntropyLoss()
    optimizer = optim.SGD(net.parameters(), lr=0.1, momentum=0.9, weight_decay=4e-5)
    
    # 3. Dummy Dataloader (Replace with actual DataLoader)
    print("Setting up dummy training loop...")
    batch_size = 16
    inputs = torch.randn(batch_size, 3, 112, 96).to(device)
    labels = torch.randint(0, 10, (batch_size,)).to(device) # dummy labels class [0-9]
    
    # For a full dummy fully-connected layer to map to 10 classes during standard training
    dummy_classifier = nn.Linear(128, 10).to(device)
    
    # 4. Training Loop
    net.train()
    epochs = 2
    for epoch in range(epochs):
        optimizer.zero_grad()
        dummy_classifier.zero_grad()
        
        features = net(inputs)
        outputs = dummy_classifier(features)
        
        loss = criterion(outputs, labels)
        loss.backward()
        
        optimizer.step()
        
        print(f"Epoch [{epoch+1}/{epochs}], Loss: {loss.item():.4f}")
        
    # 5. Save model parameters for hardware golden model comparison
    # It is recommended to freeze parameters or export to a simple text format
    torch.save(net.state_dict(), 'mobilefacenet_dummy.pth')
    print("Saved training weights to mobilefacenet_dummy.pth")

if __name__ == "__main__":
    train()
