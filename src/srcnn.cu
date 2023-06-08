/*******************************************************************************
 * SRCNN: Super-Resolution with deep Convolutional Neural Networks
 * ----------------------------------------------------------------------------
 * Current Author : Raphael Kim ( rageworx@gmail.com )
 * Latest update  : 2023-03-08
 * Pre-Author     : Wang Shu
 * Origin-Date    @ Sun 13 Sep, 2015
 * Descriptin ..
 *                 This source code modified version from Origianl code of Wang
 *                Shu's. All license following from origin.
 *******************************************************************************/
#ifndef EXPORTLIBSRCNN

////////////////////////////////////////////////////////////////////////////////
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#ifndef NO_OMP
#include <omp.h>
#endif

#include "srcnn.h"
#include "tick.h"

/* pre-calculated convolutional data */
#include "convdata.h"
#include "convdataCuda.cuh"
////////////////////////////////////////////////////////////////////////////////

#define THREAD 256
#define BLOCK 1024

static float image_multiply = 2.0f;
static unsigned image_width = 0;
static unsigned image_height = 0;
static bool opt_verbose = true;
static bool opt_debug = false;
static bool opt_help = false;
static int t_exit_code = 0;

static std::string path_me;
static std::string file_me;
static std::string file_src;
static std::string file_dst;

////////////////////////////////////////////////////////////////////////////////

#define DEF_STR_VERSION "0.1.5.20"

////////////////////////////////////////////////////////////////////////////////

/* Function Declaration */
void Convolution99(cv::Mat& src, cv::Mat& dst,
                   const float kernel[9][9], float bias);

void Convolution11(std::vector<cv::Mat>& src, cv::Mat& dst,
                   const float kernel[CONV1_FILTERS], float bias);

void Convolution55(std::vector<cv::Mat>& src, cv::Mat& dst,
                   const float kernel[32][5][5], float bias);

__global__ void Convolution99x11(uchar1* src, float* dst, int* rowf, int* colf, int height, int width);

////////////////////////////////////////////////////////////////////////////////

static inline int IntTrim(int a, int b, int c) {
    int buff[3] = {a, c, b};
    return buff[(int)(c > a) + (int)(c > b)];
}
__device__ static inline int IntTrimCuda(int a, int b, int c) {
    int buff[3] = {a, c, b};
    return buff[(int)(c > a) + (int)(c > b)];
}
/***
 * FuncName : Convolution99
 * Function : Complete one cell in the first Convolutional Layer
 * Parameter    : src - the original input image
 *        dst - the output image
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
void Convolution99(cv::Mat& src, cv::Mat& dst, const float kernel[9][9], float bias) {
    int width = dst.cols;
    int height = dst.rows;
    int row = 0;
    int col = 0;
    // macOS clang displays these array not be initialized.
    int rowf[height + 8];
    int colf[width + 8];

/* Expand the src image */
#pragma parallel for
    for (row = 0; row < height + 8; row++) {
        rowf[row] = IntTrim(0, height - 1, row - 4);
    }

#pragma parallel for
    for (col = 0; col < width + 8; col++) {
        colf[col] = IntTrim(0, width - 1, col - 4);
    }

/* Complete the Convolution Step */
#pragma omp parallel for private(col)
    for (row = 0; row < height; row++) {
        for (col = 0; col < width; col++) {
            /* Convolution */
            float temp = 0.f;

            for (int i = 0; i < 9; i++) {
                for (int j = 0; j < 9; j++) {
                    temp += kernel[i][j] * src.at<uint8_t>(rowf[row + i], colf[col + j]);
                }
            }

            temp += bias;

            /* Threshold */
            temp = (temp < 0) ? 0 : temp;

            dst.at<float>(row, col) = temp;
        }
    }
}

/***
 * FuncName : Convolution11
 * Function : Complete one cell in the second Convolutional Layer
 * Parameter    : src - the first layer data
 *        dst - the output data
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
void Convolution11(std::vector<cv::Mat>& src, cv::Mat& dst, const float kernel[CONV1_FILTERS], float bias) {
    int height = dst.rows;
    int width = dst.cols;
    int row = 0;
    int col = 0;

#pragma omp parallel for private(col)
    for (row = 0; row < height; row++) {
        for (col = 0; col < width; col++) {
            /* Process with each pixel */
            float temp = 0.f;

            for (int i = 0; i < CONV1_FILTERS; i++) {
                temp += src[i].at<float>(row, col) * kernel[i];
            }
            temp += bias;

            /* Threshold */
            temp = (temp < 0) ? 0 : temp;

            dst.at<float>(row, col) = temp;
        }
    }
}

/***
 * FuncName : Convolution55
 * Function : Complete the cell in the third Convolutional Layer
 * Parameter    : src - the second layer data
 *        dst - the output image
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
void Convolution55(std::vector<cv::Mat>& src, cv::Mat& dst, const float kernel[32][5][5], float bias) {
    int height = dst.rows;
    int width = dst.cols;
    int row = 0;
    int col = 0;
    // macOS these array not be initalized by zero.
    int rowf[height + 4];
    int colf[width + 4];

/* Expand the src image */
#pragma omp parallel for
    for (row = 0; row < height + 4; row++) {
        rowf[row] = IntTrim(0, height - 1, row - 2);
    }

#pragma omp parallel for
    for (col = 0; col < width + 4; col++) {
        colf[col] = IntTrim(0, width - 1, col - 2);
    }

/* Complete the Convolution Step */
#pragma omp parallel for private(col)
    for (row = 0; row < height; row++) {
        for (col = 0; col < width; col++) {
            float temp = 0;

            for (int i = 0; i < CONV2_FILTERS; i++) {
                double temppixel = 0;
                for (int m = 0; m < 5; m++) {
                    for (int n = 0; n < 5; n++) {
                        temppixel +=
                            kernel[i][m][n] * src[i].at<float>(rowf[row + m], colf[col + n]);
                    }
                }

                temp += temppixel;
            }

            temp += bias;

            /* Threshold */
            temp = IntTrim(0, 255, temp);

            dst.at<unsigned char>(row, col) = (unsigned char)temp;
        }
    }
}

/***
 * FuncName : Convolution99x11
 * Function : Complete one cell in the first and second Convolutional Layer
 * Parameter    : src - the original input image
 *        dst - the output image
 *        kernel - the convolutional kernel
 *        bias - the cell bias
 * Output   : <void>
 ***/
__global__ void intTrim(int* rowf, int* colf, int height, int width) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < height + 8)
        rowf[idx] = IntTrimCuda(0, height - 1, idx - 4);
    if (idx < width + 8)
        colf[idx] = IntTrimCuda(0, width - 1, idx - 4);
}
__global__ void Convolution99x11(uchar1* src, float* dst, int* rowf, int* colf, int height, int width) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    int row = 0;
    int col = 0;
    float temp[CONV1_FILTERS] = {0.f};
    // macOS llvm not able to init zero.

    /* Expand the src image */
    /* for (row = 0; row < height + 8; row++) {
        rowf[row] = IntTrimCuda(0, height - 1, row - 4);
    }

    for (col = 0; col < width + 8; col++) {
        colf[col] = IntTrimCuda(0, width - 1, col - 4);
    } */

    /* Complete the Convolution Step */
    if (idx > width * height)
        return;
    row = idx / width;
    col = idx % width;
    for (int k = 0; k < CONV1_FILTERS; k++) {
        /* Convolution */
        temp[k] = 0.0;

        for (int i = 0; i < 9; i++) {
            for (int j = 0; j < 9; j++) {
                temp[k] += weights_conv1_data_cuda[k][i][j] * src[rowf[row + i] * width * 3 + colf[col + j]].x;
                // temp[k] += weights_conv1_data_cuda[k][i][j] * src.at<uint8_t>(rowf[row + i], colf[col + j]);
            }
        }

        temp[k] += biases_conv1_cuda[k];

        /* Threshold */
        temp[k] = (temp[k] < 0) ? 0 : temp[k];
    }

    /* Process with each pixel */
    for (int k = 0; k < CONV2_FILTERS; k++) {
        float result = 0.0;

        for (int i = 0; i < CONV1_FILTERS; i++) {
            result += temp[i] * weights_conv2_data_cuda[k][i];
        }
        result += biases_conv2_cuda[k];

        /* Threshold */
        result = (result < 0) ? 0 : result;
        dst[k * width * height * 3 + row * 3 * width + col] = result;
        // dst[k].at<float>(row, col) = result;
    }
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

bool parseArgs(int argc, char** argv) {
    for (int cnt = 0; cnt < argc; cnt++) {
        std::string strtmp = argv[cnt];
        size_t fpos = std::string::npos;

        if (cnt == 0) {
            fpos = strtmp.find_last_of("\\");

            if (fpos == std::string::npos) {
                fpos = strtmp.find_last_of("/");
            }

            if (fpos != std::string::npos) {
                path_me = strtmp.substr(0, fpos);
                file_me = strtmp.substr(fpos + 1);
            } else {
                file_me = strtmp;
            }
        } else {
            if (strtmp.find("--scale=") == 0) {
                std::string strval = strtmp.substr(8);
                if (strval.size() > 0) {
                    float tmpfv = atof(strval.c_str());
                    if (tmpfv > 0.f) {
                        image_multiply = tmpfv;
                    }
                }
            } else if (strtmp.find("--noverbose") == 0) {
                opt_verbose = false;
            } else if (strtmp.find("--help") == 0) {
                opt_help = true;
            } else if (file_src.size() == 0) {
                file_src = strtmp;
            } else if (file_dst.size() == 0) {
                file_dst = strtmp;
            }
        }
    }

    if (!opt_help) {
        if ((file_src.size() > 0) && (file_dst.size() == 0)) {
            std::string convname = file_src;
            std::string srcext;

            // changes name without file extention.
            size_t posdot = file_src.find_last_of(".");
            if (posdot != std::string::npos) {
                convname = file_src.substr(0, posdot);
                srcext = file_src.substr(posdot);
            }

            convname += "_resized";
            if (srcext.size() > 0) {
                convname += srcext;
            }

            file_dst = convname;
        }

        if ((file_src.size() > 0) && (file_dst.size() > 0)) {
            return true;
        }
    }

    return false;
}

void printTitle() {
    printf("%s : Super-Resolution with deep Convolutional Neural Networks\n",
           file_me.c_str());
    printf("(C)2018..2023 Raphael Kim, (C)2014 Wang Shu., version %s\n",
           DEF_STR_VERSION);
    printf("Built with OpenCV version %s\n", CV_VERSION);
}

void printHelp() {
    printf("\n");
    printf("    usage : %s (options) [source file name] ([output file name])\n", file_me.c_str());
    printf("\n");
    printf("    _options_:\n");
    printf("\n");
    printf("        --scale=( ratio: 0.1 to .. ) : scaling by ratio.\n");
    printf("        --noverbose                  : turns off all verbose\n");
    printf("        --help                       : this help\n");
    printf("\n");
}

void* pthreadcall(void* p) {
    if (opt_verbose == true) {
        printTitle();
        printf("\n");
        printf("- Scale multiply ratio : %.2f\n", image_multiply);
        fflush(stdout);
    }

    /* Read the original image */
    cv::Mat pImgOrigin;
    unsigned start, end;
    pImgOrigin = cv::imread(file_src.c_str());

    if (pImgOrigin.empty() == false) {
        if (opt_verbose == true) {
            printf("- Image load : %s\n", file_src.c_str());
            fflush(stdout);
        }
    } else {
        if (opt_verbose == true) {
            printf("- load failure : %s\n", file_src.c_str());
        }

        t_exit_code = -1;
        pthread_exit(&t_exit_code);
    }

    // Test image resize target ...
    cv::Size testsz = pImgOrigin.size();
    if ((((float)testsz.width * image_multiply) <= 0.f) ||
        (((float)testsz.height * image_multiply) <= 0.f)) {
        if (opt_verbose == true) {
            printf("- Image scale error : ratio too small.\n");
        }

        t_exit_code = -1;
        pthread_exit(&t_exit_code);
    }

    // -------------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Image converting to Y-Cr-Cb : ");
        fflush(stdout);
    }

    unsigned perf_tick0 = tick::getTickCount();

    /* Convert the image from BGR to YCrCb Space */
    cv::Mat pImgYCrCb;
    start = tick::getTickCount();
    cvtColor(pImgOrigin, pImgYCrCb, CV_BGR2YCrCb);
    end = tick::getTickCount();
    if (pImgYCrCb.empty() == false) {
        if (opt_verbose == true) {
            printf("Ok. %u ms\n", end - start);
            fflush(stdout);
        }
    } else {
        if (opt_verbose == true) {
            printf("Failure.\n");
        }

        t_exit_code = -2;
        pthread_exit(&t_exit_code);
    }

    // ------------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Splitting channels : ");
        fflush(stdout);
    }

    /* Split the Y-Cr-Cb channel */
    std::vector<cv::Mat> pImgYCrCbCh(3);
    start = tick::getTickCount();
    split(pImgYCrCb, pImgYCrCbCh);
    end = tick::getTickCount();
    if (pImgYCrCb.empty() == false) {
        if (opt_verbose == true) {
            printf("Ok. %u ms\n", end - start);
            fflush(stdout);
        }
    } else {
        if (opt_verbose == true) {
            printf("Failure.\n");
            t_exit_code = -3;
            pthread_exit(&t_exit_code);
        }
    }

    // ------------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Resizing splitted channels with bicublic interpolation : ");
    }

    /* Resize the Y-Cr-Cb Channel with Bicubic Interpolation */
    std::vector<cv::Mat> pImg(3);
    start = tick::getTickCount();
#pragma omp parallel for
    for (int i = 0; i < 3; i++) {
        cv::Size newsz = pImgYCrCbCh[i].size();
        newsz.width *= image_multiply;
        newsz.height *= image_multiply;

        resize(pImgYCrCbCh[i],
               pImg[i],
               newsz,
               0,
               0,
               CV_INTER_CUBIC);
    }
    end = tick::getTickCount();
    if (opt_verbose == true) {
        printf("Ok. %u ms\n", end - start);
    }

    // -----------------------------------------------------------

    int cnt = 0;

    /******************* The First Layer *******************/

    if (opt_verbose == true) {
        printf("- Processing convolutional layer I + II ... ");
        fflush(stdout);
    }

    std::vector<cv::Mat> pImgConv2(CONV2_FILTERS);
    start = tick::getTickCount();

    // #pragma omp parallel for
    //     for (unsigned cnt = 0; cnt < CONV2_FILTERS; cnt++) {
    //         pImgConv2[cnt].create(pImg[0].size(), CV_32F);
    //     }
    end = tick::getTickCount();
    printf("\n  create: %u ms.", end - start);

    start = tick::getTickCount();
    // cv::cuda::GpuMat srcImg;
    // cv::cuda::GpuMat dstImg[CONV2_FILTERS];

    uchar1* srcImg;
    float* dstImg;
    float* pImgConv2Float = (float*)malloc(pImg[0].cols * pImg[0].rows * sizeof(float) * 3 * CONV2_FILTERS);
    int* rowf;
    int* colf;

    cudaMalloc(&rowf, (pImg[0].cols + 8) * sizeof(int));
    cudaMalloc(&colf, (pImg[0].rows + 8) * sizeof(int));
    cudaMalloc(&srcImg, pImg[0].cols * pImg[0].rows * sizeof(uchar1) * 3);
    cudaMalloc(&dstImg, pImg[0].cols * pImg[0].rows * sizeof(float) * 3 * CONV2_FILTERS);
    printf("\ncuda malloc complete\n");
    cudaMemcpy(srcImg, pImg[0].data, pImg[0].cols * pImg[0].rows * sizeof(uchar1), cudaMemcpyHostToDevice);
    printf("cuda memcpy complete\n");
    // Convolution99x11<<<BLOCK, THREAD>>>(pImg[0], pImgConv2, pImg[0].rows, pImg[0].cols);
    intTrim<<<16, THREAD>>>(rowf, colf, pImg[0].rows, pImg[0].cols);
    cudaDeviceSynchronize();
    Convolution99x11<<<BLOCK, THREAD>>>(srcImg, dstImg, rowf, colf, pImg[0].rows, pImg[0].cols);
    cudaDeviceSynchronize();
    printf("cuda Convolution99x11 complete\n");
    cudaMemcpy(pImgConv2Float, dstImg, pImg[0].cols * pImg[0].rows * sizeof(float) * 3 * CONV2_FILTERS, cudaMemcpyDeviceToHost);
    printf("cuda memcpy complete\n");
    for (int i = 0; i < CONV2_FILTERS; i++)
        pImgConv2[i] = cv::Mat(pImg[0].size(), CV_32F, &(pImgConv2Float[i * pImg[0].cols * pImg[0].rows * 3])).clone();
    // cudaDeviceSynchronize();
    free(pImgConv2Float);
    end = tick::getTickCount();

    printf("\n  Convolution: %u ms.\n", end - start);
    if (opt_verbose == true) {
        printf("completed.\n");
        fflush(stdout);
    }

    /******************* The Third Layer *******************/

    if (opt_verbose == true) {
        printf("- Processing convolutional layer III ... ");
        fflush(stdout);
    }

    cv::Mat pImgConv3;
    pImgConv3.create(pImg[0].size(), CV_8U);
    start = tick::getTickCount();
    Convolution55(pImgConv2, pImgConv3, weights_conv3_data, biases_conv3);
    end = tick::getTickCount();
    printf("\n  Convolution: %u ms.\n", end - start);
    if (opt_verbose == true) {
        printf("completed.\n");
        printf("- Merging images : ");
        fflush(stdout);
    }
    cudaDeviceReset();
    /* Merge the Y-Cr-Cb Channel into an image */
    start = tick::getTickCount();
    cv::Mat pImgYCrCbOut;
    pImg[0] = pImgConv3;
    merge(pImg, pImgYCrCbOut);
    end = tick::getTickCount();
    if (opt_verbose == true) {
        printf("Ok. %u ms.\n", end - start);
        fflush(stdout);
    }

    // ---------------------------------------------------------

    if (opt_verbose == true) {
        printf("- Converting channel to BGR : ");
        fflush(stdout);
    }

    /* Convert the image from YCrCb to BGR Space */
    cv::Mat pImgBGROut;
    start = tick::getTickCount();
    cvtColor(pImgYCrCbOut, pImgBGROut, CV_YCrCb2BGR);
    end = tick::getTickCount();
    unsigned perf_tick1 = tick::getTickCount();

    if (pImgBGROut.empty() == false) {
        if (opt_verbose == true) {
            printf("Ok. %u ms.\n", end - start);
            printf("- Writing result to %s : ", file_dst.c_str());
            fflush(stdout);
        }

        imwrite(file_dst.c_str(), pImgBGROut);

        if (opt_verbose == true) {
            printf("Ok.\n");
        }
    } else {
        if (opt_verbose == true) {
            printf("Failure.\n");
        }

        t_exit_code = -10;
        pthread_exit(&t_exit_code);
    }

    if (opt_verbose == true) {
        printf("- Performace : %u ms took.\n", perf_tick1 - perf_tick0);
    }

    fflush(stdout);

    t_exit_code = 0;
    pthread_exit(NULL);
    return NULL;
}

/***
 * FuncName : main
 * Function : the entry of the program
 * Parameter    : argc - the number of the initial parameters
 *        argv - the entity of the initial parameters
 * Output   : int 0 for normal / int 1 for failed
 ***/
int main(int argc, char** argv) {
    if (parseArgs(argc, argv) == false) {
        printTitle();
        printHelp();
        fflush(stdout);
        return 0;
    }

    pthread_t ptt;
    int tid = 0;
    if (pthread_create(&ptt, NULL, pthreadcall, &tid) == 0) {
        // Wait for thread ends ..
        pthread_join(ptt, NULL);
    } else {
        printf("Error: pthread failure.\n");
    }

    return t_exit_code;
}
#endif  /// of EXPORTLIBSRCNN
