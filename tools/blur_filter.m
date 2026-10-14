%% Filtro de média 3x3 aplicado a uma imagem em escala de cinza
%
% Este código lê uma imagem em escala de cinza, aplica um filtro de média
% utilizando uma máscara 3x3 e exibe a imagem original e a imagem filtrada.
%
% O kernel possui todos os elementos iguais a 1. A divisão por 9 normaliza
% o resultado, pois existem 9 elementos na máscara 3x3.
%
% A operação de convolução é realizada com a função conv2.

% Lê a imagem em escala de cinza a partir do arquivo PGM.
i = imread('grayscale_landscape.pgm');

% Define um kernel 3x3 com todos os elementos iguais a 1.
% Esse kernel será utilizado para calcular a média dos pixels vizinhos.
kernel = [1, 1, 1; 1, 1, 1; 1, 1, 1];

% Realiza a convolução 2D entre o kernel e a imagem.
% A divisão por 9 normaliza o resultado, calculando a média dos
% 9 pixels considerados pela máscara 3x3.
o = conv2(kernel, i) /9;

% Converte o resultado da convolução para o formato uint8,
% utilizado normalmente para representar imagens com intensidades
% de 0 a 255.
o = uint8(o);

% Exibe a imagem original.
figure,imshow(i);

% Exibe a imagem após a aplicação do filtro de média.
figure,imshow(o);
